# Utilise une image Node.js officielle (version LTS recommandée)
FROM node:alpine

# Clone le dépôt GitHub
WORKDIR /app
COPY . .


# Installe les dépendances Node.js
RUN npm install

# Expose le port utilisé par l'application (à adapter selon le port utilisé dans server.js)
EXPOSE 3333

# Commande pour démarrer le serveur
CMD ["node", "server.js"]
