-- Datos de prueba que simulan un esquema tipo Chatwoot (subconjunto).
CREATE TABLE accounts (
  id serial PRIMARY KEY,
  name text NOT NULL,
  created_at timestamptz DEFAULT now()
);
CREATE TABLE contacts (
  id serial PRIMARY KEY,
  account_id int REFERENCES accounts(id),
  email text,
  name text
);
CREATE TABLE conversations (
  id serial PRIMARY KEY,
  account_id int REFERENCES accounts(id),
  contact_id int REFERENCES contacts(id),
  status text DEFAULT 'open'
);
CREATE TABLE messages (
  id bigserial PRIMARY KEY,
  conversation_id int REFERENCES conversations(id),
  content text,
  created_at timestamptz DEFAULT now()
);

INSERT INTO accounts (name)
SELECT 'cuenta-' || g FROM generate_series(1, 3) g;

INSERT INTO contacts (account_id, email, name)
SELECT (g % 3) + 1, 'user' || g || '@test.co', 'Contacto ' || g
FROM generate_series(1, 50) g;

INSERT INTO conversations (account_id, contact_id, status)
SELECT (g % 3) + 1, (g % 50) + 1, CASE WHEN g % 2 = 0 THEN 'open' ELSE 'resolved' END
FROM generate_series(1, 120) g;

INSERT INTO messages (conversation_id, content)
SELECT (g % 120) + 1, 'mensaje de prueba #' || g
FROM generate_series(1, 1000) g;
