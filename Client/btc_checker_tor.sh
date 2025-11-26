#!/bin/bash

# --- CONFIGURATION ---

# Variables d'environnement pour l'API locale, l'API de solde, le proxy Tor et le fichier de log.
BASE_API_URL=${BASE_API_URL:-"http://localhost:3333/api/btc/"} 
BALANCE_API_BASE_URL=${BALANCE_API_BASE_URL:-"https://blockchain.info/balance?active="}
TOR_PROXY=${TOR_PROXY:-"socks5h://tor:9050"}
SUCCESS_LOG_FILE=${SUCCESS_LOG_FILE:-"/app/output.txt"}

# Variables pour limiter la taille du lot BATCH pour éviter l'erreur 414 Request-URI Too Large.
# Limite fixée à 450 adresses, basée sur les tests utilisateur.
MAX_BATCH_SIZE=450

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
    
    # URL de l'API Telegram
    TELEGRAM_URL="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    
    # Envoi de la requête CURL (méthode POST) en utilisant MarkdownV2
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

# Notification de lancement du script
LAUNCH_MESSAGE="✅ *Démarrage du Script Client BTC (Mode Batch)*\n"
LAUNCH_MESSAGE+="Date: $(date)\n"
LAUNCH_MESSAGE+="API cible: \`${BASE_API_URL}\`"

send_telegram_notification "$LAUNCH_MESSAGE"
echo "   ✅ Notification Telegram de lancement envoyée."


# Boucle externe: Itération sur l'index (1, 2, 3, ...)
while true; do
    
    API_URL="${BASE_API_URL}${INDEX}"
    
    # Log de l'appel de l'index
    echo "[TEST] Index externe: ${INDEX} | Appel API: ${API_URL}"

    # 1. Appel de l'API locale pour obtenir les WIF/BTCOUT
    RESPONSE=$(curl -s -m 10 "$API_URL")
    CURL_STATUS=$?

    if [ "$CURL_STATUS" -ne 0 ]; then
        echo "   ❌ Erreur CURL lors de l'appel à l'API locale. Code: $CURL_STATUS. Réessai dans 5s..."
        sleep 5
        INDEX=$((INDEX + 1)) 
        continue
    fi
    
    # 2. Extraction des données d'adresse (WIF et BTCOUT) avec limitation de taille BATCH

    # Extrait toutes les données et limite le nombre de lignes à MAX_BATCH_SIZE
    ADDRESS_DATA=$(echo "$RESPONSE" | jq -r '.bitcoin[] | "\(.wif) \(.btcout)" // empty' | head -n $MAX_BATCH_SIZE)

    if [ -z "$ADDRESS_DATA" ]; then
        echo "   [INFO] Aucune donnée d'adresse trouvée dans la réponse pour l'Index ${INDEX}."
        INDEX=$((INDEX + 1))
        continue
    fi
    
    # 3. Construction de la chaîne d'adresses pour l'appel en batch
    
    # Extraction des adresses (BTCOUT) de la liste limitée ADDRESS_DATA
    ADDRESSES_ONLY=$(echo "$ADDRESS_DATA" | awk '{print $2}')

    # Joindre les adresses par le pipe '|' et supprimer le pipe final superflu
    ADDRESS_LIST=$(echo "$ADDRESSES_ONLY" | tr '\n' '|' | sed 's/|*$//')

    # 4. Appel de l'API de solde en mode batch (une seule requête pour toutes les adresses)
    
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
    
    # 5. DIAGNOSTIC : Vérification si la réponse est JSON valide (pour détecter le Rate Limit/HTML)
    if ! echo "$BALANCE_RESPONSE" | jq empty 2>/dev/null; then
        echo "========================================================================="
        echo "   🚨 ALERTE BLOCAGE : Réponse non-JSON reçue (Rate Limit probable)."
        echo "   (Augmenter le 'sleep' ou redémarrer le service Tor.)"
        echo "========================================================================="
        sleep 30
        INDEX=$((INDEX + 1))
        continue
    fi

    # 6. Traitement des résultats (Boucle synchrone, mais rapide car local)
    
    # On itère sur les données originales (WIF + BTCOUT)
    while IFS= read -r LINE; do
        WIF=$(echo "$LINE" | awk '{print $1}')
        BTCOUT=$(echo "$LINE" | awk '{print $2}')

        # Extraction des données de solde spécifiques à cette adresse du grand JSON
        FINAL_BALANCE=$(echo "$BALANCE_RESPONSE" | jq -r ".\"$BTCOUT\".final_balance // empty")
        N_TX=$(echo "$BALANCE_RESPONSE" | jq -r ".\"$BTCOUT\".n_tx // empty") 
        
        # --- DÉBUT DE LA LOGIQUE COULEUR ET STATUT ---
        COLOR_CODE="\e[31m"       # Code couleur Rouge
        STATUS_SYMBOL="❌"
        STATUS_MESSAGE="0.00000000 BTC (0 tx) | Jamais utilisé"
        LOG_SUCCESS=false

        if [ -n "$FINAL_BALANCE" ] && [ "$FINAL_BALANCE" != "null" ]; then
            
            # Conversion en BTC pour les tests de solde
            BALANCE_BTC=$(echo "scale=8; $FINAL_BALANCE / 100000000" | bc 2>/dev/null)
            
            # Vérifie si le solde est strictement supérieur à 0
            if (( $(echo "$BALANCE_BTC > 0" | bc -l) )); then
                
                # 🏆 CAS 1 : SOLDE TROUVÉ (Couleur VERTE)
                COLOR_CODE="\e[32m" # Vert
                STATUS_SYMBOL="🎉"
                STATUS_MESSAGE="${BALANCE_BTC} BTC (${N_TX} tx) ! LOGGED"
                LOG_SUCCESS=true
                
            elif [ "$N_TX" -gt 0 ]; then
                
                # ⚠️ CAS 2 : TRANSACTIONS MAIS SOLDE NUL (Couleur JAUNE)
                COLOR_CODE="\e[33m" # Jaune
                STATUS_SYMBOL="🟡"
                STATUS_MESSAGE="0.00000000 BTC (${N_TX} tx) | Transactions antérieures"
                
            # Si le solde est 0 et N_TX est 0, il reste en ROUGE (couleur par défaut)
            fi
        fi
        # --- FIN DE LA LOGIQUE COULEUR ET STATUT ---
        
        # 💡 FORMATAGE FINAL : La couleur est appliquée uniquement au symbole et au message de statut
        printf "WIF: %-52s | Adresse: %-34s | Solde: ${COLOR_CODE}%s %s\e[0m\n" \
               "$WIF" "$BTCOUT" "$STATUS_SYMBOL" "$STATUS_MESSAGE"

        # Traitement du succès (uniquement si BTC > 0)
        if [ "$LOG_SUCCESS" = true ]; then
            
            EXPLORER_LINK="https://www.blockchain.com/fr/explorer/addresses/btc/${BTCOUT}"

            # --- Préparation et Envoi de la notification Telegram (Succès) ---
            TELEGRAM_MESSAGE="🔑 *SUCCÈS BTC TROUVÉ* \\(Index: ${INDEX}\\)\n"
            TELEGRAM_MESSAGE+="*WIF \\(Privé\\):* \`${WIF}\`\n"
            TELEGRAM_MESSAGE+="*Adresse:* \`${BTCOUT}\`\n"
            TELEGRAM_MESSAGE+="*Solde:* ${BALANCE_BTC} BTC \n"
            TELEGRAM_MESSAGE+="*Transactions:* ${N_TX} \n"
            TELEGRAM_MESSAGE+="[Vérifier sur Blockchain](${EXPLORER_LINK})"
            
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
    # DÉLAI AJUSTÉ : 5 secondes entre les appels BATCH normaux.
    sleep 5 
done
