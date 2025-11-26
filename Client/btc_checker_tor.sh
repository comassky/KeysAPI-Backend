# ... (Code avant la boucle interne reste inchangé) ...

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
    
    # 💡 MODIFICATION: Affiche la ligne de test complète (WIF et Adresse) sans retour à la ligne (\n)
    # Les codes de formatage sont des estimations : 52 caractères pour la WIF, 34 pour l'adresse.
    printf "[%s] WIF: %-52s | Adresse: %-34s | Solde: " "$INDEX" "$WIF" "$BTCOUT"

    BALANCE_RESPONSE=$(curl -s --proxy "$TOR_PROXY" "$BALANCE_URL")
    TOR_STATUS=$?
    
    if [ "$TOR_STATUS" -ne 0 ]; then
        echo "❌ Erreur CURL/Tor. Code: $TOR_STATUS"
        continue
    fi

    FINAL_BALANCE=$(echo "$BALANCE_RESPONSE" | jq -r ".\"$BTCOUT\".final_balance // empty")
    N_TX=$(echo "$BALANCE_RESPONSE" | jq -r ".\"$BTCOUT\".n_tx // empty") 
    
    if [ -n "$FINAL_BALANCE" ] && [ "$FINAL_BALANCE" != "null" ]; then
        BALANCE_BTC=$(echo "scale=8; $FINAL_BALANCE / 100000000" | bc 2>/dev/null)
        
        # Vérifie si le solde est strictement supérieur à 0
        if (( $(echo "$BALANCE_BTC > 0" | bc -l) )); then
            
            EXPLORER_LINK="https://www.blockchain.com/fr/explorer/addresses/btc/${BTCOUT}"
            
            # --- AFFICHAGE CONSOLE (Succès) : Termine la ligne avec le résultat en gras (ASCII 33) ---
            echo -e "\e[32m🎉 ${BALANCE_BTC} BTC (${N_TX} tx) ! LOGGED\e[0m" # Code couleur vert pour succès

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
    
done <<< "$ADDRESS_DETAILS"

# ... (Le reste du script est inchangé) ...
