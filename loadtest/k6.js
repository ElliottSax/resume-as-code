// Load profile for the chaos drill (scripts/drill.sh).
//
// A constant arrival rate, not a fixed number of virtual users: if the
// service slows down, k6 keeps sending at the same rate instead of politely
// backing off. That is how real traffic behaves, and it is what makes
// failures visible.
import http from 'k6/http';
import { check } from 'k6';

const TARGET = __ENV.TARGET || 'http://resume.resume.svc.cluster.local';
const RATE = parseInt(__ENV.RATE || '100', 10);
const DURATION = `${__ENV.DURATION || '180'}s`;

export const options = {
  discardResponseBodies: true,
  // Resolve DNS often enough to notice endpoint changes, and spread
  // connections across every address returned.
  dns: { ttl: '30s', select: 'random' },
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: 20,
      maxVUs: 200,
    },
  },
  // The same objectives as production (docs/slo.md). Breaching either one
  // makes k6 exit non-zero, which fails the drill and blocks the release.
  thresholds: {
    http_req_failed: ['rate<0.001'],
    http_req_duration: ['p(99)<250'],
  },
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const res = http.get(`${TARGET}/`, { timeout: '5s', tags: { name: 'index' } });
  check(res, { 'status is 200': (r) => r.status === 200 });
}

// Emit the raw summary between markers so drill.sh can parse it out of the
// pod logs without any extra storage.
export function handleSummary(data) {
  return {
    stdout: `\n===K6_SUMMARY_BEGIN===\n${JSON.stringify(data)}\n===K6_SUMMARY_END===\n`,
  };
}
