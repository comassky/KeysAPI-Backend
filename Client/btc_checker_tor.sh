#!/bin/bash

# --- CONFIGURATION (MAJ pour utiliser les variables d'environnement ou les valeurs par défaut) ---

# Utilisez ${VARIABLE:-valeur_par_defaut} pour garantir qu'une valeur est toujours présente.
BASE_API_URL=${BASE_API_URL:-"http://localhost:3333/api/btc/"} 
BALANCE_API_BASE_URL=${BALANCE_API_BASE_URL:-"https://blockchain.info/balance?active="}
TOR_PROXY=${TOR_PROXY:-"socks5h://tor:9050"}
SUCCESS_LOG_FILE=${SUCCESS_LOG_FILE:-"/app/output.txt"}

# Index de départ pour l'itération (celui-ci n'est pas configuré par compose)
INDEX=1

echo "BASE_API_URL utilisé: ${BASE_API_URL}"

echo "🚀 Démarrage du processus d'itération (Index externe) et de vérification (Boucle interne)..."
echo "   🔑 Clés trouvées (Solde > 0 BTC) seront loguées dans: ${SUCCESS_LOG_FILE}"
echo "========================================================================="

# Boucle externe: Itération sur l'index (1, 2, 3, ...)
while true; do
    
    API_URL="${BASE_API_URL}${INDEX}"
    
    # Log de l'appel de l'index
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
    
    # 2. Extraction de TOUS les objets {wif, btcout, ...} du tableau 'bitcoin'
    ADDRESS_DETAILS=$(echo "$RESPONSE" | jq -c '.bitcoin[] // empty')
    
    if [ -z "$ADDRESS_DETAILS" ]; then
        echo "   [INFO] Aucune donnée d'adresse trouvée dans la réponse pour l'Index ${INDEX}. Vérifiez le format JSON."
        INDEX=$((INDEX + 1))
        continue
    fi
    
    # Boucle interne: Traitement de chaque adresse reçue pour cet index
    while IFS= read -r DETAIL_JSON; do
        
        # Extraction des champs WIF et BTCOUT pour l'adresse courante
        WIF=$(echo "$DETAIL_JSON" | jq -r '.wif // empty')
        BTCOUT=$(echo "$DETAIL_JSON" | jq -r '.btcout // empty')

        if [ -z "$WIF" ] || [ -z "$BTCOUT" ] || [ "$WIF" == "null" ] || [ "$BTCOUT" == "null" ]; then
            echo "   [INFO] Ligne invalide: WIF ou BTCOUT manquant. Saut."
            continue 
        fi
        
        # 3. Appel de l'API de solde via Tor Proxy
        BALANCE_URL="${BALANCE_API_BASE_URL}${BTCOUT}"
        
        # Affiche la ligne de test complète (WIF + Adresse)
        printf "      [TEST] Clé: %s | Adresse: %s | Solde : " "$WIF" "$BTCOUT"

        BALANCE_RESPONSE=$(curl -s --proxy "$TOR_PROXY" "$BALANCE_URL")
        TOR_STATUS=$?
        
        if [ "$TOR_STATUS" -ne 0 ]; then
            echo "❌ Erreur CURL/Tor. Code: $TOR_STATUS"
            continue
        fi

        FINAL_BALANCE=$(echo "$BALANCE_RESPONSE" | jq -r ".\"$BTCOUT\".final_balance // empty")
        
        if [ -n "$FINAL_BALANCE" ] && [ "$FINAL_BALANCE" != "null" ]; then
            BALANCE_BTC=$(echo "scale=8; $FINAL_BALANCE / 100000000" | bc 2>/dev/null)
            
            # 💡 Vérifie si le solde est strictement supérieur à 0
            if (( $(echo "$BALANCE_BTC > 0" | bc -l) )); then
                
                # --- AFFICHAGE CONSOLE (Succès) ---
                # Affiche le solde BTC sur la même ligne que le test (pas de saut de ligne précédent)
                echo "🎉 ${BALANCE_BTC} BTC ! (Logging dans ${SUCCESS_LOG_FILE})" 

                # --- LOGGING DANS LE FICHIER (tee -a) ---
                echo "--------------------------------------------------------" | tee -a "$SUCCESS_LOG_FILE"
                echo "Date: $(date)" | tee -a "$SUCCESS_LOG_FILE"
                echo "Index Source: ${INDEX}" | tee -a "$SUCCESS_LOG_FILE"
                echo "WIF (PRIVATE KEY): ${WIF}" | tee -a "$SUCCESS_LOG_FILE"
                printf "Adresse: %s | Solde (Satoshis): %s | Solde (BTC): %s\n" \
                       "$BTCOUT" "$FINAL_BALANCE" "$BALANCE_BTC" | tee -a "$SUCCESS_LOG_FILE"
                # ---------------------------------------------
                
            else
                # Solde est 0
                echo "0.00000000 BTC"
            fi
        else
            echo "⚠️ Non trouvé/Invalide"
        fi
        
    done <<< "$ADDRESS_DETAILS"

    # Incrémentation de l'index et pause
    INDEX=$((INDEX + 1))
done