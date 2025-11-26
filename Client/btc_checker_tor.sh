#!/bin/bash

# --- CONFIGURATION ---

# Variables d'environnement pour l'API locale, l'API de solde, le proxy Tor et le fichier de log.
BASE_API_URL=${BASE_API_URL:-"http://localhost:3333/api/btc/"} 
BALANCE_API_BASE_URL=${BALANCE_API_BASE_URL:-"https://blockchain.info/balance?active="}
TOR_PROXY=${TOR_PROXY:-"socks5h://tor:9050"}
SUCCESS_LOG_FILE=${SUCCESS_LOG_FILE:-"/app/output.txt"}

# 💡 MAX_BATCH_SIZE est lu depuis l'environnement (ex: Docker Compose). Défaut à 450.
MAX_BATCH_SIZE=${MAX_BATCH_SIZE:-450}

# Variables d'environnement pour Telegram (DOIVENT être définies dans docker-compose)
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-"VOTRE_TOKEN_DE_BOT_PAR_DEFAUT"} 
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-"VOTRE_ID_DE_CHAT_PAR_DEFAUT"}

# Index de départ pour l'itération
INDEX=1

# --- FONCTION TELEGRAM ---

# Fonction pour envoyer une notification Telegram
send_telegram_notification() {
    local message="$1"
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo "   ⚠️ Erreur Telegram: Token ou Chat ID manquant. Notification non envoyée."
        return 1
    fi
    
    TELEGRAM_URL="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    
    curl -s -X POST "$TELEGRAM_URL" \
         -d chat_id="$TELEGRAM_CHAT_ID" \
         -d text="$message" \
         -d parse_mode="MarkdownV2" > /dev/null
}

# --- DÉMARRAGE DU SCRIPT ---

echo "🚀 Démarrage du processus optimisé (Batch) d'itération et de vérification..."
echo "   🔑 Clés trouvées (Solde > 0 BTC) seront loguées dans: ${SUCCESS_LOG_FILE}"
echo "   📏 Limite Batch par requête: ${MAX_BATCH_SIZE} adresses."
echo "========================================================================="

LAUNCH_MESSAGE="✅ *Démarrage du Script Client BTC (Mode Batch)*\nDate: $(date)\nAPI cible: \`${BASE_API_URL}\`"
send_telegram_notification "$LAUNCH_MESSAGE"
echo "   ✅ Notification Telegram de lancement envoyée."


# Boucle externe: Itération sur l'index (1, 2, 3, ...)
while true; do
    
    API_URL="${BASE_API_URL}${INDEX}"
    echo "[TEST] Index externe: ${INDEX} | Appel API: ${API_URL}"

    # 1. Appel de l'API locale
    RESPONSE=$(curl -s -m 10 "$API_URL")
    CURL_STATUS=$?

    if [ "$CURL_STATUS" -ne 0 ]; then
        echo "   ❌ Erreur CURL lors de l'appel à l'API locale. Code: $CURL_STATUS. Réessai dans 5s..."
        sleep 5
        INDEX=$((INDEX + 1)) 
        continue
    fi
    
    # 2. Extraction des données d'adresse (WIF et BTCOUT) avec limitation de taille BATCH
    ADDRESS_DATA=$(echo "$RESPONSE" | jq -r '.bitcoin[] | "\(.wif) \(.btcout)" // empty' | head -n "$MAX_BATCH_SIZE")

    if [ -z "$ADDRESS_DATA" ]; then
        echo "   [INFO] Aucune donnée d'adresse trouvée dans la réponse pour l'Index ${INDEX}."
        INDEX=$((INDEX + 1))
        continue
    fi
    
    # 3. Construction de la chaîne d'adresses pour l'appel en batch
    ADDRESS_LIST=$(echo "$ADDRESS_DATA" | awk '{print $2}' | paste -s -d '|' -)

    # 4. Appel de l'API de solde en mode batch
    BALANCE_URL="${BALANCE_API_BASE_URL}${ADDRESS_LIST}"
    echo "   [BATCH] Requête unique pour $(echo "$ADDRESS_DATA" | wc -l) adresses..."
    
    BALANCE_RESPONSE=$(curl -s --proxy "$TOR_PROXY" "$BALANCE_URL")
    TOR_STATUS=$?
    
    if [ "$TOR_STATUS" -ne 0 ]; then
        echo "❌ Erreur CURL/Tor lors de l'appel BATCH. Code: $TOR_STATUS. Pause longue et réessai..."
        sleep 30
        INDEX=$((INDEX + 1))
        continue
    fi
    
    # 5. DIAGNOSTIC JSON
    if ! echo "$BALANCE_RESPONSE" | jq empty 2>/dev/null; then
        echo "========================================================================="
        echo "   🚨 ALERTE BLOCAGE : Réponse non-JSON reçue (Rate Limit probable)."
        echo "========================================================================="
        sleep 30
        INDEX=$((INDEX + 1))
        continue
    fi

    # 6. Traitement des résultats
    
    while IFS= read -r LINE; do
        read -r WIF BTCOUT <<< "$LINE"

        # Extraction des données de solde spécifiques (Sécurisé par // 0)
        FINAL_BALANCE=$(echo "$BALANCE_RESPONSE" | jq -r ".\"$BTCOUT\".final_balance // 0")
        N_TX=$(echo "$BALANCE_RESPONSE" | jq -r ".\"$BTCOUT\".n_tx // 0") 
        
        # --- LOGIQUE COULEUR ET STATUT ---
        COLOR_CODE="\e[31m"       # Rouge (Défaut : Inactif)
        STATUS_SYMBOL="❌"
        LOG_SUCCESS=false

        if [ "$FINAL_BALANCE" -gt 0 ]; then
            
            # 🏆 CAS 1 : SOLDE TROUVÉ (Vert)
            COLOR_CODE="\e[32m" # Vert
            STATUS_SYMBOL="🎉"
            LOG_SUCCESS=true
            
        elif [ "$N_TX" -gt 0 ]; then
            
            # ⚠️ CAS 2 : TRANSACTIONS MAIS SOLDE NUL (Jaune)
            COLOR_CODE="\e[33m" # Jaune
            STATUS_SYMBOL="🟡"
        
        # Sinon, reste en ROUGE
        fi
        
        # Calcul et message de statut
        if [ "$FINAL_BALANCE" -gt 0 ]; then
            BALANCE_BTC=$(echo "scale=8; $FINAL_BALANCE / 100000000" | bc 2>/dev/null)
            STATUS_MESSAGE="${BALANCE_BTC} BTC (${N_TX} tx) $([ "$LOG_SUCCESS" = true ] && echo "! LOGGED")"
        else
            BALANCE_BTC="0.00000000"
            STATUS_MESSAGE="${BALANCE_BTC} BTC (${N_TX} tx)"
        fi

        
        # FORMATAGE FINAL : Applique la couleur uniquement au symbole et au message de statut
        printf "WIF: %-52s | Adresse: %-34s | Solde: ${COLOR_CODE}%s %s\e[0m\n" \
               "$WIF" "$BTCOUT" "$STATUS_SYMBOL" "$STATUS_MESSAGE"

        # Traitement du succès (uniquement si BTC > 0)
        if [ "$LOG_SUCCESS" = true ]; then
            
            EXPLORER_LINK="https://www.blockchain.com/fr/explorer/addresses/btc/${BTCOUT}"

            # --- Préparation et Envoi de la notification Telegram (Succès) ---
            TELEGRAM_MESSAGE="🔑 *SUCCÈS BTC TROUVÉ* \\(Index: ${INDEX}\\)\n*WIF \\(Privé\\):* \`${WIF}\`\n*Adresse:* \`${BTCOUT}\`\n*Solde:* ${BALANCE_BTC} BTC \n*Transactions:* ${N_TX} \n[Vérifier sur Blockchain](${EXPLORER_LINK})"
            send_telegram_notification "$TELEGRAM_MESSAGE"
            # --------------------------------------------------------

            # --- LOGGING DANS LE FICHIER (tee -a) ---
            echo "--------------------------------------------------------" | tee -a "$SUCCESS_LOG_FILE"
            echo "Date: $(date)" | tee -a "$SUCCESS_LOG_FILE"
            echo "Index Source: ${INDEX}" | tee -a "$SUCCESS_LOG_FILE"
            echo "WIF (PRIVATE KEY): ${WIF}" | tee -a "$SUCCESS_LOG_FILE"
            echo "Lien Blockchain: ${EXPLORER_LINK}" | tee -a "$SUCCESS_LOG_FILE" 
            printf "Adresse: %s | Transactions: %s | Solde (Satoshis): %s | Solde (BTC): %s\n" \
                   "$BTCOUT" "$N_TX" "$FINAL_BALANCE" "$BALANCE_BTC" | tee -a "$SUCCESS_LOG_FILE"
        
        fi
        
    done <<< "$ADDRESS_DATA"


    # Incrémentation de l'index et pause
    INDEX=$((INDEX + 1))
    # 💡 DÉLAI AJUSTÉ : 2 secondes entre les appels BATCH.
    sleep 2 
done
