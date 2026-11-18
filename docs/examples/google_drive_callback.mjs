import { createHash } from 'node:crypto';
import { createServer } from 'node:http';

const callbackPath = '/googleui/callback';
const sessionLifetime = 5 * 60 * 1000;
const sessions = new Map();
const base64UrlKey = /^[A-Za-z0-9_-]{43}$/;

function reply(response, status, data) {
  response.statusCode = status;
  if (typeof data === 'string') {
    response.setHeader('Content-Type', 'text/plain; charset=utf-8');
    response.end(data);
  } else if (data !== undefined) {
    response.setHeader('Content-Type', 'application/json');
    response.end(JSON.stringify(data));
  } else {
    response.end();
  }
}

const server = createServer(async (request, response) => {
  response.setHeader('Cache-Control', 'no-store');
  response.setHeader('Referrer-Policy', 'no-referrer');

  const url = URL.parse(request.url, 'http://localhost');
  if (!url || url.pathname !== callbackPath) {
    return reply(response, 404);
  }

  if (request.method === 'GET') {
    const state = url.searchParams.get('state');
    if (state === null) {
      return reply(response, 200, '请返回 VeneraPlus 查看授权状态。 Return to VeneraPlus to check authorization.');
    }
    const session = sessions.get(state);
    if (!session || session.expiresAt <= Date.now()) {
      return reply(response, 410, '授权会话已过期，请在 VeneraPlus 重新授权。 Start a new authorization in VeneraPlus.');
    }
    const code = url.searchParams.get('code');
    if (code && code.length <= 4096) {
      session.result ??= { state, code };
    } else if (url.searchParams.has('error')) {
      session.result ??= { state, error: 'authorization_denied' };
    } else {
      return reply(response, 400, '缺少授权结果。 Missing authorization result.');
    }
    response.setHeader('Location', callbackPath);
    return reply(response, 303);
  }

  if (request.method !== 'POST') {
    response.setHeader('Allow', 'GET, POST');
    return reply(response, 405);
  }

  let message;
  try {
    const chunks = [];
    let length = 0;
    for await (const chunk of request.iterator({ destroyOnReturn: false })) {
      length += chunk.length;
      if (length > 1024) {
        request.resume();
        return reply(response, 413);
      }
      chunks.push(chunk);
    }
    message = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    return reply(response, 400);
  }

  if (message?.action === 'start' &&
      typeof message.state === 'string' && base64UrlKey.test(message.state)) {
    const state = message.state;
    if (sessions.has(state)) return reply(response, 409);
    if (sessions.size >= 256) return reply(response, 503);
    const timer = setTimeout(() => sessions.delete(state), sessionLifetime).unref();
    sessions.set(state, { timer, expiresAt: Date.now() + sessionLifetime });
    return reply(response, 201, { protocol: 'venera-google-drive-v1' });
  }

  if (message?.action === 'take' &&
      typeof message.poll_key === 'string' && base64UrlKey.test(message.poll_key)) {
    const state = createHash('sha256').update(message.poll_key).digest('base64url');
    const session = sessions.get(state);
    if (!session || session.expiresAt <= Date.now()) return reply(response, 410);
    if (!session.result) return reply(response, 202);
    clearTimeout(session.timer);
    sessions.delete(state);
    return reply(response, 200, session.result);
  }

  return reply(response, 400);
});

const port = Number(process.env.GOOGLE_DRIVE_CALLBACK_PORT ?? 8787);
server.listen(port, '127.0.0.1');
