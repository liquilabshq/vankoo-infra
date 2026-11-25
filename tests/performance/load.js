// Carga: el uso esperado en la demo y algo más. Sube a 20 usuarios, los mantiene 5 min y baja.
import { sleep } from 'k6';
import { browseMarketplace, signIn, thresholds } from './lib.js';

export const options = {
  stages: [
    { duration: '1m', target: 20 },
    { duration: '5m', target: 20 },
    { duration: '1m', target: 0 },
  ],
  thresholds,
};

export function setup() { return signIn(); }

export default function (session) {
  browseMarketplace(session);
  sleep(1);
}
