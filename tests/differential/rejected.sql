INSERT INTO dept VALUES (1, 'duplicate key', 1)
INSERT INTO dept VALUES (99, 'dept-01', 1)
INSERT INTO emp (name, salary, hired) VALUES (NULL, 1, '2026-01-01')
UPDATE dept SET name = 'dept-02' WHERE id = 1
UPDATE emp SET name = NULL WHERE id = 20
SELECT missing FROM emp
SELECT * FROM nowhere
