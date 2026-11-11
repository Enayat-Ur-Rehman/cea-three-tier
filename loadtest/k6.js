// Load test that drives the app tier's CPU above the 50% scaling target, so the
// Auto Scaling Groups scale out, then lets traffic stop so they scale back in.
//
//   docker run --rm -i -e BASE_URL=https://<id>.cloudfront.net grafana/k6 run - < loadtest/k6.js
//
// Many virtual users with small responses: run from a home connection, large
// responses run out of bandwidth before the servers run out of CPU.
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = (__ENV.BASE_URL || 'http://localhost:8080').replace(/\/$/, '');
const SEED = parseInt(__ENV.SEED || '20', 10);
const PEAK = parseInt(__ENV.PEAK_VUS || '600', 10);
const HOLD = __ENV.HOLD || '12m';

export const options = {
  setupTimeout: '5m',
  teardownTimeout: '5m',
  stages: [
    { duration: '2m', target: PEAK },   // ramp up
    { duration: HOLD, target: PEAK },   // hold: long enough for alarms + new hosts
    { duration: '1m', target: 0 },      // ramp down; scale-in follows after ~15 min
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],     // under 1% errors while scaling
    http_req_duration: ['p(95)<3000'],
  },
};

export function setup() {
  const have = http.get(`${BASE}/api/tasks`).json('tasks').length;
  for (let i = have; i < SEED; i++) {
    http.post(`${BASE}/api/tasks`, JSON.stringify({ title: `load-seed-${i}` }),
      { headers: { 'Content-Type': 'application/json' } });
  }
  return { seeded: Math.max(SEED - have, 0) };
}

export default function () {
  const r = http.get(`${BASE}/api/tasks`, { tags: { name: 'list' } });
  check(r, { 'list 200': (x) => x.status === 200 });
  const i = http.get(`${BASE}/api/info`, { tags: { name: 'info' } });
  check(i, { 'info 200': (x) => x.status === 200 });
  sleep(0.2);
}

// Remove the seeded rows so the live demo list is clean again.
export function teardown() {
  const r = http.get(`${BASE}/api/tasks`, { timeout: '120s' });
  const tasks = r.status === 200 ? r.json('tasks') : [];
  for (const t of tasks) {
    if (String(t.title).startsWith('load-seed-')) {
      http.del(`${BASE}/api/tasks/${t.id}`);
    }
  }
}
