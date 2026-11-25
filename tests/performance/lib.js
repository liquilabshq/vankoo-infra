// Común a las pruebas de k6: URL base, inicio de sesión del inversionista y las
// peticiones de lectura que hace la app móvil al abrir el mercado.
import http from 'k6/http';
import { check, fail } from 'k6';

export const BASE_URL = __ENV.BASE_URL || 'https://vankoo-liquilabs.centralus.cloudapp.azure.com';

// Mismos objetivos que los SLO del monitoreo (k8s/monitoring): p95 < 1 s y < 1 % de errores.
export const thresholds = {
  http_req_failed: ['rate<0.01'],
  http_req_duration: ['p(95)<1000'],
  'http_req_duration{name:marketplace}': ['p(95)<1000'],
  checks: ['rate>0.99'],
};

/** Inicia sesión una vez (setup) con la cuenta de prueba del inversionista. */
export function signIn() {
  const email = __ENV.K6_INVESTOR_EMAIL;
  const password = __ENV.K6_INVESTOR_PASSWORD;
  if (!email || !password) {
    fail('Define K6_INVESTOR_EMAIL y K6_INVESTOR_PASSWORD (ver tests/performance/README.md)');
  }
  const res = http.post(`${BASE_URL}/iam/api/v1/authentication/sign-in`,
    JSON.stringify({ email, password }),
    { headers: { 'Content-Type': 'application/json' }, tags: { name: 'sign-in' } });
  if (res.status !== 200) fail(`El inicio de sesión respondió ${res.status}`);
  const body = res.json();
  return { token: body.token, userId: body.id };
}

/** Lo que pide la app al abrir el mercado: lista, filtro verde, una subasta y la billetera. */
export function browseMarketplace(session) {
  const params = (name) => ({ headers: { Authorization: `Bearer ${session.token}` }, tags: { name } });

  const list = http.get(`${BASE_URL}/investment/api/v1/auctions/marketplace?size=20`, params('marketplace'));
  check(list, { 'mercado 200': (r) => r.status === 200 });

  const green = http.get(`${BASE_URL}/investment/api/v1/auctions/marketplace?greenCertified=true`, params('marketplace-green'));
  check(green, { 'filtro verde 200': (r) => r.status === 200 });

  const auctions = list.status === 200 ? list.json('content') : [];
  if (auctions && auctions.length > 0) {
    const auction = auctions[Math.floor(Math.random() * auctions.length)];
    const detail = http.get(`${BASE_URL}/investment/api/v1/auctions/${auction.auctionId}`, params('auction-detail'));
    check(detail, { 'detalle 200': (r) => r.status === 200 });
  }

  const wallet = http.get(`${BASE_URL}/finance/api/v1/accounts/${session.userId}/wallets/PEN`, params('wallet'));
  check(wallet, { 'billetera 200': (r) => r.status === 200 });
}
