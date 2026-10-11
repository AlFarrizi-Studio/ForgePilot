import http from 'node:http';
const server = http.createServer((req, res) => { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end('{"ok":true}'); });
if (process.argv[3] === 'crash') process.exit(7);
if (process.argv[3] !== 'never-ready') server.listen(Number(process.argv[2]), '127.0.0.1');
const timer = setInterval(() => {}, 10000);
process.on('SIGTERM', () => { clearInterval(timer); server.close(() => process.exit(0)); if (!server.listening) process.exit(0); });
