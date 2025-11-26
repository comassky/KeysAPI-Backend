import CoinKey from 'coinkey';
import { Buffer } from 'buffer'; // Importez Buffer si vous n'êtes pas dans un environnement Node.js moderne

export default function generateBitcoinInfo(hexKeys) {
  const bitcoinInfo = [];

  for (const hexKey of hexKeys) {
    try {
      // Créez l'objet CoinKey sans spécifier de paramètres réseau.
      // CoinKey utilise par défaut les paramètres Bitcoin (préfixe WIF 0x80).
      const btc = CoinKey(Buffer.from(hexKey, 'hex')); 

      // Par défaut, CoinKey génère une clé WIF NON COMPRESSÉE (commence par '5').
      const wif = btc.privateWif; 
      
      // Si vous souhaitez une clé WIF COMPRESSÉE (commence par 'K' ou 'L'),
      // vous devez définir 'compressed' à true avant d'accéder à privateWif :
      // btc.compressed = true;
      // const compressedWif = btc.privateWif;

      const btcout = btc.publicAddress;

      bitcoinInfo.push({ hex: hexKey, wif, btcout });
    } catch (error) {
      // J'ai renommé l'erreur de "Litecoin" à "Bitcoin" pour plus de clarté
      console.error(`Erreur lors de la génération des infos Bitcoin pour la clé hex ${hexKey}: ${error.message}`);
    }
  }

  return bitcoinInfo;
}
