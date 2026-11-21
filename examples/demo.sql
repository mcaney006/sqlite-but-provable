CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT NOT NULL UNIQUE,
    age INTEGER CHECK (age >= 0)
);

CREATE TABLE orders (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL,
    total REAL NOT NULL
);

CREATE INDEX idx_orders_user
ON orders(user_id);

BEGIN;

INSERT INTO users
VALUES (1, 'Alice', 'alice@example.com', 27);

INSERT INTO users
VALUES (2, 'Bob', 'bob@example.com', 31);

INSERT INTO orders
VALUES (100, 1, 149.99);

INSERT INTO orders
VALUES (101, 1, 89.50);

INSERT INTO orders
VALUES (102, 2, 250.00);

COMMIT;

SELECT
    u.name,
    COUNT(o.id) AS order_count,
    SUM(o.total) AS lifetime_value
FROM users AS u
INNER JOIN orders AS o
    ON u.id = o.user_id
GROUP BY u.id, u.name
HAVING COUNT(o.id) > 0
ORDER BY lifetime_value DESC;

EXPLAIN QUERY PLAN
SELECT *
FROM orders
WHERE user_id = 1;

BEGIN;

UPDATE users
SET age = 28
WHERE id = 1;

ROLLBACK;

SELECT age
FROM users
WHERE id = 1;
