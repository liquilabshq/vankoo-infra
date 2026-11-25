// Estrés: sube por escalones hasta 80 usuarios para ver dónde se degrada y cómo responde
// el autoescalado (HPA al 70 % de CPU en gateway, IAM, Investment, Invoicing y Profile).
// Los umbrales son más laxos: aquí se busca el punto de quiebre, no aprobar el SLO.
import { sleep } from 'k6';
import { browseMarketplace, signIn } from './lib.js';

export const options = {
  stages: [
    { duration: '2m', target: 20 },
    { duration: '3m', target: 40 },
    { duration: '3m', target: 80 },
    { duration: '3m', target: 80 },
    { duration: '2m', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<3000'],
  },
};

export function setup() { return signIn(); }

export default function (session) {
  browseMarketplace(session);
  sleep(0.5);
}
