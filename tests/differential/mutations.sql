UPDATE emp SET salary = salary + 500 WHERE dept_id = 4
UPDATE emp SET dept_id = NULL WHERE salary % 97 = 0
UPDATE emp SET rating = rating + 0.25, name = name || '-x' WHERE id % 11 = 0
UPDATE emp SET dept_id = 12 WHERE id BETWEEN 400 AND 420
DELETE FROM emp WHERE salary < 32000
DELETE FROM emp WHERE dept_id = 9 AND rating IS NULL
DELETE FROM project WHERE id % 4 = 0
UPDATE dept SET budget = budget * 2 WHERE id <= 3
INSERT INTO emp (name, dept_id, salary, rating, hired) VALUES ('late', 5, 99999, 4.5, '2026-01-01')
INSERT INTO emp VALUES (100000, 'far', NULL, 31000, NULL, '2026-02-02')
INSERT INTO emp (name, dept_id, salary, rating, hired) VALUES ('later', 6, 88888, NULL, '2026-03-03')
UPDATE emp SET id = id + 200000 WHERE id BETWEEN 10 AND 12
