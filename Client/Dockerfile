# Utilise la distribution Alpine, extrêmement légère et sécurisée
FROM alpine:latest

# Mise à jour et installation des outils nécessaires au script Bash :
# - bash: Pour exécuter le script (Alpine utilise sh par défaut)
# - curl: Pour les requêtes HTTP
# - jq: Pour l'analyse et la manipulation du JSON
# - bc: Pour les calculs en virgule flottante (conversion Satoshis -> BTC)
RUN apk update && \
    apk add --no-cache bash curl jq bc

# Création du répertoire de travail à l'intérieur du conteneur
WORKDIR /app

# Copie du script Bash local vers le répertoire de travail du conteneur
# Assurez-vous que votre script est dans le même répertoire que le Dockerfile
COPY btc_checker_tor.sh /app/

# Rendre le script exécutable
RUN chmod +x /app/btc_checker_tor.sh

# Définition du point d'entrée du conteneur.
# Lorsque le conteneur démarrera, il exécutera ce script en utilisant bash.
# Note: Utilisez la forme exec [] pour une bonne gestion des signaux par Docker.
ENTRYPOINT ["/bin/bash", "/app/btc_checker_tor.sh"]
