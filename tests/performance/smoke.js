// Humo: 1 usuario durante 30 s. Comprueba que el script y la cuenta funcionan antes de cargar.
import { sleep } from 'k6';
import { browseMarketplace, signIn, thresholds } from './lib.js';

export const options = { vus: 1, duration: '30s', thresholds };

export function setup() { return signIn(); }

export default function (session) {
  browseMarketplace(session);
  sleep(1);
}
