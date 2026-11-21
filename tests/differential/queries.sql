SELECT COUNT(*) FROM emp
SELECT COUNT(*), COUNT(dept_id), COUNT(rating), COUNT(DISTINCT dept_id) FROM emp
SELECT SUM(salary), MIN(salary), MAX(salary) FROM emp
SELECT CAST(AVG(salary) AS INTEGER) FROM emp
SELECT SUM(rating), MIN(rating), MAX(rating) FROM emp
SELECT id, name, salary FROM emp WHERE id = 1234
SELECT id, name FROM emp WHERE id BETWEEN 100 AND 110 ORDER BY id
SELECT id, name FROM emp WHERE id > 2990 ORDER BY id
SELECT id FROM emp WHERE id < 6 OR id >= 2998 ORDER BY id
SELECT id, salary FROM emp WHERE salary = 50000 ORDER BY id
SELECT id, salary FROM emp WHERE salary > 149000 ORDER BY salary, id
SELECT id, salary FROM emp WHERE salary >= 30000 AND salary < 30400 ORDER BY salary, id
SELECT id FROM emp WHERE dept_id = 7 AND salary > 140000 ORDER BY id
SELECT id FROM emp WHERE dept_id IS NULL ORDER BY id LIMIT 25
SELECT id FROM emp WHERE dept_id IS NOT NULL AND rating IS NULL ORDER BY id LIMIT 25
SELECT COUNT(*) FROM emp WHERE dept_id = NULL
SELECT COUNT(*) FROM emp WHERE dept_id <> 3
SELECT COUNT(*) FROM emp WHERE NOT (dept_id = 3)
SELECT COUNT(*) FROM emp WHERE dept_id = 3 OR dept_id <> 3
SELECT COUNT(*) FROM emp WHERE dept_id IN (1, 2, 3)
SELECT COUNT(*) FROM emp WHERE dept_id NOT IN (1, 2, 3)
SELECT COUNT(*) FROM emp WHERE dept_id IN (1, NULL)
SELECT COUNT(*) FROM emp WHERE dept_id NOT IN (1, NULL)
SELECT COUNT(*) FROM emp WHERE rating > 2.5
SELECT COUNT(*) FROM emp WHERE rating > 2
SELECT COUNT(*) FROM emp WHERE salary / 1000 = 77
SELECT COUNT(*) FROM emp WHERE salary % 7 = 3
SELECT COUNT(*) FROM emp WHERE name LIKE 'emp12%'
SELECT COUNT(*) FROM emp WHERE name LIKE 'EMP_5'
SELECT COUNT(*) FROM emp WHERE name LIKE '%99'
SELECT COUNT(*) FROM emp WHERE name NOT LIKE 'e%'
SELECT COUNT(*) FROM emp WHERE LENGTH(name) = 6
SELECT COUNT(*) FROM emp WHERE UPPER(name) = 'EMP42'
SELECT COUNT(*) FROM emp WHERE hired >= '2019-06-01' AND hired < '2020-01-01'
SELECT id, name || '/' || hired FROM emp WHERE id <= 5 ORDER BY id
SELECT id, salary + 1, salary - 1, salary * 2, salary / 7, salary % 7, -salary FROM emp WHERE id <= 5 ORDER BY id
SELECT id, rating * 2, rating + 1, rating - 0.5 FROM emp WHERE id <= 12 ORDER BY id
SELECT id, COALESCE(dept_id, -1), COALESCE(rating, 0.0) FROM emp WHERE id <= 40 ORDER BY id
SELECT id, ABS(salary - 90000) FROM emp WHERE id <= 8 ORDER BY id
SELECT id, CAST(rating AS INTEGER), CAST(salary AS REAL) / 2 FROM emp WHERE id <= 12 ORDER BY id
SELECT id, CAST(salary AS TEXT) || 'x' FROM emp WHERE id <= 5 ORDER BY id
SELECT id, salary / 0, salary % 0 FROM emp WHERE id <= 3 ORDER BY id
SELECT dept_id, COUNT(*) FROM emp GROUP BY dept_id ORDER BY dept_id
SELECT dept_id, COUNT(*), SUM(salary), MIN(salary), MAX(salary) FROM emp GROUP BY dept_id ORDER BY dept_id
SELECT dept_id, COUNT(rating), SUM(rating) FROM emp GROUP BY dept_id ORDER BY dept_id
SELECT dept_id, COUNT(*) FROM emp WHERE salary > 100000 GROUP BY dept_id HAVING COUNT(*) > 90 ORDER BY dept_id
SELECT dept_id, COUNT(*) AS n FROM emp GROUP BY dept_id HAVING SUM(salary) > 22000000 ORDER BY n DESC, dept_id
SELECT salary % 5, COUNT(*) FROM emp GROUP BY salary % 5 ORDER BY 1
SELECT dept_id, salary % 3, COUNT(*) FROM emp GROUP BY dept_id, salary % 3 ORDER BY 1, 2
SELECT COUNT(DISTINCT salary), COUNT(DISTINCT rating), COUNT(DISTINCT hired) FROM emp
SELECT DISTINCT dept_id FROM emp ORDER BY dept_id
SELECT DISTINCT dept_id, salary % 2 FROM emp ORDER BY dept_id, salary % 2
SELECT DISTINCT rating FROM emp ORDER BY rating
SELECT id FROM emp ORDER BY salary DESC, id LIMIT 15
SELECT id FROM emp ORDER BY salary, id LIMIT 15 OFFSET 2900
SELECT id FROM emp ORDER BY rating DESC, id DESC LIMIT 15
SELECT id FROM emp ORDER BY rating, id LIMIT 15
SELECT id FROM emp ORDER BY dept_id, salary DESC, id LIMIT 15
SELECT id FROM emp ORDER BY name LIMIT 12
SELECT id FROM emp ORDER BY hired DESC, id LIMIT 12
SELECT id FROM emp ORDER BY id DESC LIMIT 5 OFFSET 7
SELECT id FROM emp ORDER BY id LIMIT 0
SELECT d.name, COUNT(e.id) FROM dept d LEFT JOIN emp e ON e.dept_id = d.id GROUP BY d.id, d.name ORDER BY d.id
SELECT d.name, COUNT(e.id), SUM(e.salary) FROM dept AS d INNER JOIN emp AS e ON e.dept_id = d.id GROUP BY d.id, d.name HAVING COUNT(e.id) > 0 ORDER BY 3 DESC, 1
SELECT e.id, d.name FROM emp e JOIN dept d ON d.id = e.dept_id WHERE e.salary > 149500 ORDER BY e.id
SELECT e.id, d.name FROM emp e LEFT JOIN dept d ON d.id = e.dept_id WHERE e.id <= 30 ORDER BY e.id
SELECT e.id, d.name FROM emp e LEFT JOIN dept d ON d.id = e.dept_id AND d.budget > 500000 WHERE e.id <= 30 ORDER BY e.id
SELECT COUNT(*) FROM emp e LEFT JOIN dept d ON d.id = e.dept_id WHERE d.id IS NULL
SELECT COUNT(*) FROM dept d LEFT JOIN emp e ON e.dept_id = d.id WHERE e.id IS NULL
SELECT COUNT(*) FROM emp e JOIN dept d ON e.dept_id = d.id WHERE d.budget > e.salary * 4
SELECT COUNT(*) FROM emp a JOIN emp b ON a.salary = b.salary AND a.id < b.id
SELECT a.id, b.id FROM emp a JOIN emp b ON a.salary = b.salary AND a.id < b.id ORDER BY a.id, b.id LIMIT 20
SELECT COUNT(*) FROM dept a CROSS JOIN dept b
SELECT COUNT(*) FROM dept a, dept b WHERE a.budget < b.budget
SELECT d.name, p.title FROM dept d JOIN project p ON p.dept_id = d.id ORDER BY p.id
SELECT d.name, COUNT(p.id), COUNT(DISTINCT e.id) FROM dept d LEFT JOIN project p ON p.dept_id = d.id LEFT JOIN emp e ON e.dept_id = d.id AND e.salary > 148000 GROUP BY d.id, d.name ORDER BY d.id
SELECT e.id, p.title FROM emp e JOIN dept d ON d.id = e.dept_id JOIN project p ON p.dept_id = d.id WHERE e.id <= 20 ORDER BY e.id, p.id
SELECT name FROM dept WHERE name = 'dept-07'
SELECT id FROM dept WHERE budget BETWEEN 200000 AND 700000 ORDER BY id
SELECT 1 + 2 * 3, (1 + 2) * 3, 7 / 2, -7 / 2, 7 % 3, -7 % 3, 2 - 3 - 4
SELECT 1.5 + 1, 10 / 4.0, 'a' || 'b', LENGTH('abc'), ABS(-4), ABS(-2.5)
SELECT COALESCE(NULL, 3), COALESCE(NULL, NULL), 1 / 0, NULL + 1, NULL || 'a'
SELECT CAST('42' AS INTEGER), CAST(3.9 AS INTEGER), CAST(-3.9 AS INTEGER), CAST(7 AS TEXT), CAST(2 AS REAL)
SELECT id, name, dept_id, salary, rating, hired FROM emp ORDER BY id
SELECT id, name, budget FROM dept ORDER BY id
SELECT id, dept_id, title FROM project ORDER BY id
