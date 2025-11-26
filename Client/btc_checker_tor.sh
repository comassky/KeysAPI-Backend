#!/bin/bash

# --- CONFIGURATION (Utilise les variables d'environnement de Docker Compose ou des valeurs par défaut) ---

# Variables d'environnement pour l'API locale, l'API de solde, le proxy Tor et le fichier de log.
BASE_API_URL=${BASE_API_URL:-"http://localhost:3333/api/btc/"} 
BALANCE_API_BASE_URL=${BALANCE_API_BASE_URL:-"https://blockchain.info/balance?active="}
TOR_PROXY=${TOR_PROXY:-"socks5h://tor:9050"}
SUCCESS_LOG_FILE=${SUCCESS_LOG_FILE:-"/app/output.txt"}

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
echo "========================================================================="

# Notification de lancement du script
LAUNCH_MESSAGE="✅ *Démarrage du Script Client BTC (Mode Batch)*\n"
LAUNCH_MESSAGE+="Date: $(date)\n"
LAUNCH_MESSAGE+="API cible: \`${BASE_API_URL}\`\n"
LAUNCH_MESSAGE+="Logging: \`${SUCCESS_LOG_FILE}\`"

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
    
    # Extraction de TOUTES les données d'adresse
    ADDRESS_DATA=$(echo "$RESPONSE" | jq -r '.bitcoin[] | "\(.wif) \(.btcout)" // empty')
    
    if [ -z "$ADDRESS_DATA" ]; then
        echo "   [INFO] Aucune donnée d'adresse trouvée dans la réponse pour l'Index ${INDEX}."
        INDEX=$((INDEX + 1))
        continue
    fi
    
    # 2. Construction de la chaîne d'adresses pour l'appel en batch
    # On itère sur ADDRESS_DATA pour collecter uniquement les adresses (BTCOUT)
    ADDRESS_LIST=""
    while IFS= read -r LINE; do
        BTCOUT=$(echo "$LINE" | awk '{print $2}')
        if [ -n "$ADDRESS_LIST" ]; then
            ADDRESS_LIST="${ADDRESS_LIST}|${BTCOUT}"
        else
            ADDRESS_LIST="${BTCOUT}"
        fi
    done <<< "$ADDRESS_DATA"


    # 3. Appel de l'API de solde en mode batch (une seule requête pour toutes les adresses)
    
    BALANCE_URL="${BALANCE_API_BASE_URL}${ADDRESS_LIST}"
    echo "   [BATCH] Requête unique pour $(echo "$ADDRESS_DATA" | wc -l) adresses..."
    
    BALANCE_RESPONSE=$(curl -s --proxy "$TOR_PROXY" "$BALANCE_URL")
    TOR_STATUS=$?
    
    if [ "$TOR_STATUS" -ne 0 ]; then
        echo "❌ Erreur CURL/Tor lors de l'appel BATCH. Code: $TOR_STATUS"
        INDEX=$((INDEX + 1))
        continue
    fi

    # 4. Traitement des résultats (Boucle synchrone, mais rapide car local)
    
    # On itère sur les données originales (WIF + BTCOUT)
    while IFS= read -r LINE; do
        WIF=$(echo "$LINE" | awk '{print $1}')
        BTCOUT=$(echo "$LINE" | awk '{print $2}')

        # Extraction des données de solde spécifiques à cette adresse du grand JSON
        FINAL_BALANCE=$(echo "$BALANCE_RESPONSE" | jq -r ".\"$BTCOUT\".final_balance // empty")
        N_TX=$(echo "$BALANCE_RESPONSE" | jq -r ".\"$BTCOUT\".n_tx // empty") 
        
        # Affiche la ligne de test complète (WIF et Adresse)
        printf "[%s] WIF: %-52s | Adresse: %-34s | Solde: " "$INDEX" "$WIF" "$BTCOUT"

        if [ -n "$FINAL_BALANCE" ] && [ "$FINAL_BALANCE" != "null" ]; then
            BALANCE_BTC=$(echo "scale=8; $FINAL_BALANCE / 100000000" | bc 2>/dev/null)
            
            # Vérifie si le solde est strictement supérieur à 0
            if (( $(echo "$BALANCE_BTC > 0" | bc -l) )); then
                
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

                # --- AFFICHAGE CONSOLE (Succès) ---
                echo -e "\e[32m🎉 ${BALANCE_BTC} BTC (${N_TX} tx) ! LOGGED\e[0m"

                # --- LOGGING DANS LE FICHIER (tee -a) ---
                echo "--------------------------------------------------------" | tee -a "$SUCCESS_LOG_FILE"
                echo "Date: $(date)" | tee -a "$SUCCESS_LOG_FILE"
                echo "Index Source: ${INDEX}" | tee -a "$SUCCESS_LOG_FILE"
                echo "WIF (PRIVATE KEY): ${WIF}" | tee -a "$SUCCESS_LOG_FILE"
                echo "Lien Blockchain: ${EXPLORER_LINK}" | tee -a "$SUCCESS_LOG_FILE" 
                printf "Adresse: %s | Transactions: %s | Solde (Satoshis): %s | Solde (BTC): %s\n" \
                       "$BTCOUT" "$N_TX" "$FINAL_BALANCE" "$BALANCE_BTC" | tee -a "$SUCCESS_LOG_FILE"
                
            else
                # Solde est 0 : Termine la ligne avec le résultat vide
                echo "0.00000000 BTC (${N_TX} tx)"
            fi
        else
            # Erreur : Termine la ligne avec un message d'erreur
            echo "⚠️ Non trouvé/Invalide"
        fi
        
    done <<< "$ADDRESS_DATA"


    # Incrémentation de l'index et pause
    INDEX=$((INDEX + 1))
done
