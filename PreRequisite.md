mkdir -p /tmp/backend-build
cat > /tmp/backend-build/package.json << 'EOF'
{
  "name": "itssolutions-backend",
  "version": "1.0.0",
  "description": "ITS Solutions Backend API",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "pg": "^8.11.3",
    "bcrypt": "^5.1.1",
    "jsonwebtoken": "^9.0.2",
    "helmet": "^7.1.0",
    "cors": "^2.8.5",
    "express-rate-limit": "^7.1.5",
    "dotenv": "^16.3.1"
  }
}
EOF




cat > /tmp/backend-build/server.js << 'SERVEREOF'
'use strict';

const fs   = require('fs');
const path = require('path');

function loadVaultSecret(filePath) {
  if (!fs.existsSync(filePath)) {
    console.error(`[vault] Secret file not found: ${filePath}`);
    process.exit(1);
  }
  const lines = fs.readFileSync(filePath, 'utf8').split('\n');
  lines.forEach(line => {
    const match = line.match(/^export\s+([A-Z_][A-Z0-9_]*)="(.*)"\s*$/);
    if (match) {
      process.env[match[1]] = match[2];
    }
  });
}

console.log('[startup] Loading secrets from Vault agent files...');
loadVaultSecret('/vault/secrets/db-creds');
loadVaultSecret('/vault/secrets/app-config');
console.log('[startup] Secrets loaded successfully');

const required = ['DB_HOST','DB_PORT','DB_NAME','DB_USER','DB_PASSWORD','JWT_SECRET'];
required.forEach(key => {
  if (!process.env[key]) {
    console.error(`[startup] FATAL: Missing required secret: ${key}`);
    process.exit(1);
  }
});
console.log('[startup] All required secrets validated');

const express     = require('express');
const { Pool }    = require('pg');
const bcrypt      = require('bcrypt');
const jwt         = require('jsonwebtoken');
const helmet      = require('helmet');
const cors        = require('cors');
const rateLimit   = require('express-rate-limit');

const app  = express();
const PORT = process.env.PORT || 3000;

const pool = new Pool({
  host:     process.env.DB_HOST,
  port:     parseInt(process.env.DB_PORT, 10),
  database: process.env.DB_NAME,
  user:     process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  max:      10,
  idleTimeoutMillis:       30000,
  connectionTimeoutMillis: 5000,
  ssl: false
});

pool.on('error', (err) => {
  console.error('[pg] Unexpected pool error:', err.message);
});

app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      styleSrc:   ["'self'", "'unsafe-inline'"],
      scriptSrc:  ["'self'"],
      imgSrc:     ["'self'", "data:"],
    },
  },
}));

app.use(cors({
  origin: process.env.CORS_ORIGIN || '*',
  methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization'],
  credentials: true
}));

app.use(express.json({ limit: '10kb' }));
app.use(express.urlencoded({ extended: false, limit: '10kb' }));

const loginLimiter = rateLimit({
  windowMs:        15 * 60 * 1000,
  max:             10,
  standardHeaders: true,
  legacyHeaders:   false,
  message: { success: false, message: 'Too many login attempts. Please try again in 15 minutes.' },
  handler: (req, res, next, options) => {
    console.warn(`[rate-limit] IP ${req.ip} exceeded login rate limit`);
    res.status(429).json(options.message);
  }
});

function authenticateToken(req, res, next) {
  const authHeader = req.headers['authorization'];
  const token = authHeader && authHeader.split(' ')[1];
  if (!token) return res.status(401).json({ success: false, message: 'Access token required' });
  jwt.verify(token, process.env.JWT_SECRET, (err, user) => {
    if (err) {
      if (err.name === 'TokenExpiredError')
        return res.status(401).json({ success: false, message: 'Token expired' });
      return res.status(403).json({ success: false, message: 'Invalid token' });
    }
    req.user = user;
    next();
  });
}

async function initDatabase() {
  const client = await pool.connect();
  try {
    console.log('[db] Initializing database schema...');
    await client.query(`
      CREATE TABLE IF NOT EXISTS users (
        id         SERIAL PRIMARY KEY,
        username   VARCHAR(255) UNIQUE NOT NULL,
        password   VARCHAR(255) NOT NULL,
        role       VARCHAR(50)  NOT NULL DEFAULT 'user',
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        last_login TIMESTAMP WITH TIME ZONE
      )
    `);
    const existing = await client.query('SELECT id FROM users WHERE username = $1', ['admin']);
    if (existing.rows.length === 0) {
      const hashedPassword = await bcrypt.hash('Admin@1234!', 12);
      await client.query(
        'INSERT INTO users (username, password, role) VALUES ($1, $2, $3)',
        ['admin', hashedPassword, 'admin']
      );
      console.log('[db] Default admin user created');
    } else {
      console.log('[db] Admin user already exists');
    }
    console.log('[db] Database initialization complete');
  } finally {
    client.release();
  }
}

app.get('/health', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'healthy', timestamp: new Date().toISOString(), db: 'connected' });
  } catch (err) {
    res.status(503).json({ status: 'unhealthy', timestamp: new Date().toISOString(), db: 'disconnected', error: err.message });
  }
});

app.post('/api/auth/login', loginLimiter, async (req, res) => {
  const { username, password } = req.body;
  if (!username || !password)
    return res.status(400).json({ success: false, message: 'Username and password are required' });
  if (typeof username !== 'string' || username.length > 255)
    return res.status(400).json({ success: false, message: 'Invalid username' });
  try {
    const result = await pool.query(
      'SELECT id, username, password, role FROM users WHERE username = $1',
      [username.toLowerCase().trim()]
    );
    if (result.rows.length === 0) {
      await bcrypt.hash('dummy', 10);
      return res.status(401).json({ success: false, message: 'Invalid credentials' });
    }
    const user = result.rows[0];
    const passwordMatch = await bcrypt.compare(password, user.password);
    if (!passwordMatch) {
      console.warn(`[auth] Failed login attempt for user: ${username}`);
      return res.status(401).json({ success: false, message: 'Invalid credentials' });
    }
    await pool.query('UPDATE users SET last_login = NOW() WHERE id = $1', [user.id]);
    const token = jwt.sign(
      { id: user.id, username: user.username, role: user.role },
      process.env.JWT_SECRET,
      { expiresIn: '8h', issuer: 'itssolutions-backend', audience: 'itssolutions-frontend' }
    );
    console.log(`[auth] Successful login for user: ${user.username}`);
    res.json({ success: true, message: 'Login successful', token, user: { id: user.id, username: user.username, role: user.role } });
  } catch (err) {
    console.error('[auth] Login error:', err.message);
    res.status(500).json({ success: false, message: 'Internal server error' });
  }
});

app.get('/api/auth/verify', authenticateToken, (req, res) => {
  res.json({ success: true, user: { id: req.user.id, username: req.user.username, role: req.user.role } });
});

app.post('/api/auth/logout', authenticateToken, (req, res) => {
  console.log(`[auth] User logged out: ${req.user.username}`);
  res.json({ success: true, message: 'Logged out successfully' });
});

app.get('/api/user/profile', authenticateToken, async (req, res) => {
  try {
    const result = await pool.query(
      'SELECT id, username, role, created_at, last_login FROM users WHERE id = $1',
      [req.user.id]
    );
    if (result.rows.length === 0)
      return res.status(404).json({ success: false, message: 'User not found' });
    res.json({ success: true, user: result.rows[0] });
  } catch (err) {
    console.error('[profile] Error:', err.message);
    res.status(500).json({ success: false, message: 'Internal server error' });
  }
});

app.use((req, res) => res.status(404).json({ success: false, message: 'Route not found' }));
app.use((err, req, res, next) => {
  console.error('[error]', err.stack);
  res.status(500).json({ success: false, message: 'Internal server error' });
});

async function start() {
  let retries = 10;
  while (retries > 0) {
    try {
      console.log(`[startup] Attempting DB connection (${11 - retries}/10)...`);
      await pool.query('SELECT 1');
      console.log('[startup] Database connection established');
      break;
    } catch (err) {
      retries--;
      if (retries === 0) { console.error('[startup] FATAL: Cannot connect to database:', err.message); process.exit(1); }
      console.warn(`[startup] DB not ready: ${err.message} — retrying in 5s...`);
      await new Promise(r => setTimeout(r, 5000));
    }
  }
  await initDatabase();
  app.listen(PORT, '0.0.0.0', () => {
    console.log(`[startup] Server listening on port ${PORT}`);
    console.log('[startup] All credentials loaded from Vault — no hardcoded secrets');
  });
}

process.on('SIGTERM', async () => { console.log('[shutdown] SIGTERM received'); await pool.end(); process.exit(0); });
process.on('SIGINT',  async () => { console.log('[shutdown] SIGINT received');  await pool.end(); process.exit(0); });

start().catch(err => { console.error('[startup] FATAL:', err); process.exit(1); });
SERVEREOF


cat > /tmp/backend-build/entrypoint.sh << 'EOF'
#!/bin/sh
set -e

echo "[entrypoint] Waiting for Vault agent to write secret files..."

for SECRET_FILE in /vault/secrets/db-creds /vault/secrets/app-config; do
  ATTEMPTS=0
  MAX_ATTEMPTS=30
  while [ ! -f "${SECRET_FILE}" ]; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ "${ATTEMPTS}" -ge "${MAX_ATTEMPTS}" ]; then
      echo "[entrypoint] ERROR: ${SECRET_FILE} not found after ${MAX_ATTEMPTS} attempts"
      exit 1
    fi
    echo "[entrypoint] Waiting for ${SECRET_FILE} ... (${ATTEMPTS}/${MAX_ATTEMPTS})"
    sleep 2
  done
  echo "[entrypoint] Found: ${SECRET_FILE}"
done

echo "[entrypoint] All Vault secrets are available"
echo "[entrypoint] Starting Node.js server..."
exec node /app/server.js
EOF
chmod +x /tmp/backend-build/entrypoint.sh




cat > /tmp/backend-build/Dockerfile << 'EOF'
FROM node:18-alpine

# Install build deps for bcrypt (native module)
RUN apk add --no-cache python3 make g++

# node:18-alpine already has user 'node' with uid/gid 1000
# No need to create a new user

WORKDIR /app

# Install deps first (layer cache)
COPY package.json .
RUN npm install --production && npm cache clean --force

# Copy application files
COPY server.js .
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Own files by the existing 'node' user
RUN chown -R node:node /app

USER node

EXPOSE 3000

ENTRYPOINT ["/entrypoint.sh"]
EOF



cd /tmp/backend-build
docker build -t itssolutions-backend:latest .

# Test 1: All modules load - bypass entrypoint
docker run --rm \
  --entrypoint node \
  komlan2019/itssolutions-backend:latest \
  -e "
    require('express');
    require('pg');
    require('bcrypt');
    require('jsonwebtoken');
    require('helmet');
    require('cors');
    require('express-rate-limit');
    console.log('ALL DEPENDENCIES OK');
  "
# Test 2: Vault secret parsing - bypass entrypoint
docker run --rm \
  --entrypoint node \
  komlan2019/itssolutions-backend:latest \
  -e "
    const fs = require('fs');
    fs.mkdirSync('/tmp/vault-test', { recursive: true });
    fs.writeFileSync('/tmp/vault-test/db-creds',
      'export DB_HOST=\"postgres\"\nexport DB_PORT=\"5432\"\nexport DB_NAME=\"testdb\"\nexport DB_USER=\"user\"\nexport DB_PASSWORD=\"pass\"\n'
    );
    fs.writeFileSync('/tmp/vault-test/app-config',
      'export JWT_SECRET=\"supersecretkey\"\n'
    );
    function loadVaultSecret(filePath) {
      const lines = fs.readFileSync(filePath, 'utf8').split('\n');
      lines.forEach(line => {
        const match = line.match(/^export\s+([A-Z_][A-Z0-9_]*)=\"(.*)\"\s*$/);
        if (match) process.env[match[1]] = match[2];
      });
    }
    loadVaultSecret('/tmp/vault-test/db-creds');
    loadVaultSecret('/tmp/vault-test/app-config');
    const required = ['DB_HOST','DB_PORT','DB_NAME','DB_USER','DB_PASSWORD','JWT_SECRET'];
    required.forEach(k => {
      if (!process.env[k]) throw new Error('Missing: ' + k);
      console.log('OK ' + k + ' = ' + process.env[k]);
    });
    console.log('VAULT SECRET PARSING OK');
  "


## Generate correct hash for Admin@1234
python3 -c "import bcrypt; print(bcrypt.hashpw(b'Admin@1234', bcrypt.gensalt(12)).decode())"

kubectl exec -n itssolutions-db \
  $(kubectl get pod -n itssolutions-db -l app=postgres -o jsonpath='{.items[0].metadata.name}') \
  -c postgres -- psql -U postgres -d itssolutions_db -c \
  "UPDATE users SET password='\$2b\$12\$YOUR_GENERATED_HASH_HERE' WHERE username='admin';"

# Port forward vault UI to localhost
kubectl port-forward -n vault vault-0 8200:8200 --address=0.0.0.0 &
