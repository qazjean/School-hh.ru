-- ============================================================
-- Домашнее задание к лекции «SQL. Введение»
-- Школа Аналитиков · учебная база hh_school
-- Автор: Джафарова Фарида Зауровна
-- ============================================================
-- Формат: задания по порядку, каждое начинается с комментария
-- с номером; под каждым запросом — вывод (2–3 предложения).
-- Запрос без вывода не засчитывается.
-- ============================================================

SET search_path TO hh_school;


-- ============================================================
-- БЛОК А. Разминка: термины и структура (текстом)
-- ============================================================

-- ЗАДАНИЕ А1
-- 1. Категория и конкретный тип колонок:
--    vacancies.salary_from        — категория: числовой       тип: INT
--    vacancies.vacancy_name       — категория: строковый      тип: VARCHAR (в базе объявлена как TEXT)
--    vacancies.published_at       — категория: дата и время   тип: TIMESTAMP
--    employers.is_accredited_it   — категория: логический     тип: BOOLEAN
--    responses.created_at         — категория: дата и время   тип: TIMESTAMP
--
-- 2. Первичные ключи таблиц:
--    areas: area_id
--    employers: employer_id
--    vacancies: vacancy_id
--    vacancy_details: vacancy_id (чем особенный: он одновременно первичный ключ и внешний ключ
--       на vacancies. Своего id у описания нет, поэтому у вакансии может быть максимум одно
--       описание — это и есть связь 1:1. Описание есть не у всех: 45 строк на 52 вакансии)
--    responses: response_id
--
-- 3. Почему vacancy_name не может быть первичным ключом:
--    Первичный ключ должен быть уникальным и непустым, а одно и то же название вакансии
--    встречается у разных компаний и в разных городах. К тому же vacancy_name не объявлена NOT NULL.
--    Запрос для подтверждения числом:

-- запрос:
SELECT vacancy_name,
       count(*) AS cnt
FROM vacancies
GROUP BY vacancy_name
ORDER BY cnt DESC
LIMIT 1;

-- Вывод: самое частое название «Стажёр: аналитик данных» встречается 6 раз, то есть под одним
-- названием лежат 6 разных вакансий. По названию нельзя однозначно найти строку, поэтому ключом
-- служит vacancy_id.
--
-- 4. Что произойдёт при записи строки «по договорённости» в salary_from:
--    Будет ошибка: invalid input syntax for type integer. Это хорошо, потому что в колонке
--    гарантированно лежат только числа, и avg, sum и сравнения по зарплате всегда считаются
--    правильно. Если зарплата не указана, для этого есть NULL.


-- ============================================================
-- БЛОК Б. Первые запросы: SELECT, WHERE, ORDER BY
-- ============================================================

-- ЗАДАНИЕ Б1
-- Запрос: experience
SELECT DISTINCT experience
FROM vacancies
ORDER BY experience;

-- Запрос: employment
SELECT DISTINCT employment
FROM vacancies
ORDER BY employment;

-- Запрос: professional_role
SELECT DISTINCT professional_role
FROM vacancies
ORDER BY professional_role;

-- Вывод: в experience 3 значения, в employment 3, в professional_role 5.
-- Проблем с качеством не нашла: нет одного значения в разных написаниях, лишних пробелов, 
-- так что можно фильтровать прямо по этим строкам.


-- ЗАДАНИЕ Б2
-- Запрос 1: стажировки в Москве без опыта, вакансия открыта
SELECT vacancy_id,
       vacancy_name,
       salary_from,
       published_at
FROM vacancies
WHERE area_id = 1                     -- Москва
  AND employment = 'Стажировка'
  AND experience = 'Нет опыта'
  AND closed_at IS NULL               -- вакансия ещё открыта
ORDER BY published_at DESC;

-- Запрос 2: топ-10 вакансий по salary_from
SELECT vacancy_name,
       professional_role,
       salary_from
FROM vacancies
ORDER BY salary_from DESC NULLS LAST  -- иначе при DESC наверх встают вакансии без зарплаты
LIMIT 10;

-- Вывод: открытых стажировок без опыта в Москве 8; если убрать условие про Москву, их станет
-- всего 10, то есть почти все такие стажировки в Москве.
-- Самая свежая опубликована 3 июня, а три висят ещё с января, так что
-- откликаться лучше начинать со свежих, старые могли уже фактически набрать людей.
-- В топ-10 по зарплате только Senior и опытные позиции (максимум у Senior разработчика, 195 000).


-- ЗАДАНИЕ Б3
-- Ловушка 1. NULL — выполнить и объяснить результат
SELECT count(*) FROM vacancies WHERE closed_at = NULL;     -- 0
SELECT count(*) FROM vacancies WHERE closed_at IS NULL;    -- 33

-- Ловушка 2. AND / OR — выполнить и объяснить результат
SELECT count(*) FROM vacancies
WHERE area_id = 1 OR area_id = 2 AND experience = 'Нет опыта';     -- 31

SELECT count(*) FROM vacancies
WHERE (area_id = 1 OR area_id = 2) AND experience = 'Нет опыта';   -- 20

-- Вывод:
-- Ловушка 1. Запрос синтаксически правильный, поэтому ошибки нет. Но сравнение с NULL даёт
-- не TRUE, а «неизвестно», и WHERE отбрасывает все строки, получается 0 вместо 33.
-- Это опаснее ошибки, потому что 0 выглядит как правдоподобный ответ и его легко не заметить.
-- NULL в closed_at означает, что вакансия ещё не закрыта, то есть открыта.
--
-- Ловушка 2. AND выполняется раньше OR, поэтому база прочитала условие как
-- area_id = 1 OR (area_id = 2 AND experience = 'Нет опыта'): все 26 вакансий Москвы плюс
-- 5 питерских без опыта = 31. На вопрос «Москва или Петербург, но обязательно без опыта»
-- отвечает второй запрос со скобками — 20 вакансий.


-- ============================================================
-- БЛОК В. Агрегации и метрики
-- ============================================================

-- ЗАДАНИЕ В1
-- Запрос 1: счётчики (строки, зарплата указана, направления, работодатели)
SELECT count(*)                          AS total_rows,
       count(salary_from)                AS with_salary_from,
       count(DISTINCT professional_role) AS roles_cnt,
       count(DISTINCT employer_id)       AS employers_cnt
FROM vacancies;

-- Запрос 2: доля активных вакансий (без JOIN)
SELECT count(*) FILTER (WHERE closed_at IS NULL)     AS open_cnt,
       count(*) FILTER (WHERE closed_at IS NOT NULL) AS closed_cnt,
       round(100.0 * count(*) FILTER (WHERE closed_at IS NULL)
             / nullif(count(*), 0), 1)                AS open_pct
FROM vacancies;

-- Вывод: count(*) = 52 — это все строки таблицы. count(salary_from) = 44, потому что он
-- пропускает NULL: у 8 вакансий зарплата не указана. count(DISTINCT) считает только разные
-- значения: направлений 5, работодателей 12, хотя строк 52.
-- Ответ руководителю: «Сейчас открыто 33 вакансии из 52 — это 63,5%».


-- ЗАДАНИЕ В2
-- Запрос 1: направления — вакансии, работодатели, средняя зарплата
SELECT professional_role,
       count(*)                    AS vacancies_cnt,
       count(DISTINCT employer_id) AS employers_cnt,
       round(avg(salary_from))     AS avg_salary_from
FROM vacancies
GROUP BY professional_role
ORDER BY vacancies_cnt DESC;

-- Запрос 2: то же, только направления с ≥ 5 открытыми вакансиями (WHERE + HAVING)
SELECT professional_role,
       count(*)                    AS vacancies_cnt,
       count(DISTINCT employer_id) AS employers_cnt,
       round(avg(salary_from))     AS avg_salary_from
FROM vacancies
WHERE closed_at IS NULL            -- фильтр строк: только открытые
GROUP BY professional_role
HAVING count(*) >= 5               -- фильтр групп: не меньше 5
ORDER BY vacancies_cnt DESC;

-- Вывод:
-- Больше половины рынка — «Аналитик данных» (16) и «Разработчик» (15), вместе 31 из 52.
-- Соискатель решил бы, что туда и надо идти, но в таблице нет конкуренции и шанса на
-- приглашение (сколько откликов на вакансию и какая конверсия), а без этого вывод не обоснован.
-- «Только открытые» — условие на строки, оно проверяется до группировки, поэтому в WHERE.
-- «Не менее пяти» — условие на группу, его можно проверить только после GROUP BY, поэтому HAVING.
-- WHERE count(*) >= 5 выдаст ошибку, так как на этапе WHERE групп ещё нет.
-- avg(salary_from) отвечает на вопрос «какая средняя нижняя граница зарплаты среди вакансий,
-- где она указана». Но не отвечает на «сколько реально платят» или «сколько получит стажёр»:
-- это только нижняя граница, вакансии без зарплаты не учтены, а стажёры и Senior смешаны вместе.


-- ============================================================
-- БЛОК Г. Соединение таблиц
-- ============================================================

-- ЗАДАНИЕ Г1
-- Запрос: топ-5 по salary_from с названием компании и городом (псевдонимы таблиц)
SELECT v.vacancy_name,
       e.employer_name,
       a.area_name,
       v.salary_from
FROM vacancies v
JOIN employers e ON v.employer_id = e.employer_id
JOIN areas a     ON v.area_id = a.area_id
ORDER BY v.salary_from DESC NULLS LAST
LIMIT 5;

-- Вывод: в топ-5 только Senior-вакансии, первое место — Senior разработчик в «Северном Коде»
-- (Санкт-Петербург, 195 000). Если написать просто area_id, будет ошибка
-- column reference "area_id" is ambiguous: эта колонка есть и в vacancies, и в employers,
-- и в areas, и база не понимает, какую брать.


-- ЗАДАНИЕ Г2
-- Запрос 1: все работодатели, число вакансий и откликов (LEFT JOIN)
SELECT e.employer_name,
       count(DISTINCT v.vacancy_id) AS vacancies_cnt,
       count(r.response_id)         AS responses_cnt
FROM employers e
LEFT JOIN vacancies v ON e.employer_id = v.employer_id
LEFT JOIN responses r ON v.vacancy_id = r.vacancy_id
GROUP BY e.employer_id, e.employer_name
ORDER BY responses_cnt DESC;

-- Запрос 2: тот же запрос с INNER JOIN
SELECT e.employer_name,
       count(DISTINCT v.vacancy_id) AS vacancies_cnt,
       count(r.response_id)         AS responses_cnt
FROM employers e
INNER JOIN vacancies v ON e.employer_id = v.employer_id
INNER JOIN responses r ON v.vacancy_id = r.vacancy_id
GROUP BY e.employer_id, e.employer_name
ORDER BY responses_cnt DESC;

-- Вывод: с LEFT JOIN 12 строк, с INNER JOIN 11.
-- После присоединения откликов каждая вакансия повторяется столько раз, сколько у неё откликов,
-- поэтому count(*) посчитал бы строки «вакансия × отклик» (у ТехноБанка 157 вместо 9 вакансий);
-- count(DISTINCT v.vacancy_id) считает каждую вакансию один раз.
-- Во втором запросе пропала «ГринЭнерго» — у неё одна вакансия и ноль откликов. Это именно та
-- компания, про которую HR хотел спросить, почему нет интереса, а в отчёте с INNER JOIN её просто нет.
-- Правило: если нужны все объекты основной таблицы, включая те, у кого ноль, — LEFT JOIN;
-- если нужны только объекты, у которых точно есть пара, — INNER JOIN.


-- ============================================================
-- БЛОК Д. Функции и финальный кейс
-- ============================================================

-- ЗАДАНИЕ Д1
-- Запрос: помесячная динамика откликов и конверсия
-- (месяц как дата, условный агрегат, nullif в знаменателе)
SELECT date_trunc('month', created_at)::date                AS month,
       count(*)                                             AS responses_cnt,
       count(*) FILTER (WHERE status = 'invited')           AS invited_cnt,
       round(100.0 * count(*) FILTER (WHERE status = 'invited')
             / nullif(count(*), 0), 1)                      AS conversion_pct
FROM responses
GROUP BY 1
ORDER BY 1;

-- Вывод: максимальная конверсия в июне — 19,5% (118 откликов, 23 приглашения).
-- Доверять этому для планирования нельзя: приглашений в месяц всего от 4 до 23, и разница между
-- месяцами — это несколько приглашений, а данные есть только за 8 месяцев одного года,
-- так что сезонность не проверить.
-- Август неполный — отклики только до 15-го (41 штука), и многие ещё не рассмотрены,
-- поэтому его конверсия 7,3% занижена и его лучше исключить.


-- ЗАДАНИЕ Д2
-- Запрос: таблица по направлениям (вакансии, отклики, приглашения,
-- откликов на вакансию, конверсия)
SELECT v.professional_role,
       count(DISTINCT v.vacancy_id)                              AS vacancies_cnt,
       count(r.response_id)                                      AS responses_cnt,
       count(r.response_id) FILTER (WHERE r.status = 'invited')  AS invited_cnt,
       round(1.0 * count(r.response_id)
             / nullif(count(DISTINCT v.vacancy_id), 0), 1)       AS responses_per_vacancy,
       round(100.0 * count(r.response_id) FILTER (WHERE r.status = 'invited')
             / nullif(count(r.response_id), 0), 1)               AS conversion_pct
FROM vacancies v
LEFT JOIN responses r ON v.vacancy_id = r.vacancy_id   -- LEFT, чтобы вакансии без откликов попали в знаменатель
GROUP BY v.professional_role
ORDER BY conversion_pct DESC;

-- Письменные ответы:
-- 1. Совпадает ли направление с наибольшим числом вакансий с направлением
--    с наибольшей конверсией?
--    Нет. Больше всего вакансий у аналитика данных (16), но конверсия там 12,1%.
--    Самая высокая конверсия у тестировщика — 35,9%.
--
-- 2. Какое направление выбрать и почему (опираясь на два столбца):
--    Тестировщик: у него меньше всего конкуренция (5,6 отклика на вакансию против 19,6
--    у аналитика данных) и выше всего конверсия (35,9%, примерно каждый третий отклик).
--
-- 3. Оговорка к выводу:
--    У тестировщиков мало данных — 39 откликов и 14 приглашений, так что процент может сильно
--    меняться. И данные не говорят, кто откликался: возможно, туда просто идут более
--    подготовленные кандидаты.


-- ============================================================
-- БЛОК Е. Со звёздочкой
-- ============================================================

-- ЗАДАНИЕ Е1
-- Исходный запрос (выполнить и посмотреть результат):
-- SELECT v.professional_role,
-- count(*) AS vacancies,
-- sum(v.salary_from) AS total_salary,
-- count(r.response_id) / count(*) AS responses_per_vacancy
-- FROM vacancies v
-- JOIN responses r ON v.vacancy_id = r.vacancy_id
-- WHERE v.closed_at = NULL
-- GROUP BY 1;
--
-- Результат: 0 строк.
--
-- Ошибки (минимум четыре):
-- 1. WHERE v.closed_at = NULL — сравнение с NULL никогда не TRUE, поэтому запрос возвращает
--    0 строк. Нужно IS NULL.
-- 2. count(*) AS vacancies после JOIN считает не вакансии, а строки «вакансия × отклик»
--    (у аналитиков данных 236 вместо 11). Нужно count(DISTINCT v.vacancy_id).
-- 3. count(r.response_id) / count(*) — деление целых чисел, дробная часть отбрасывается,
--    к тому же числитель и знаменатель тут одинаковые, и везде получается 1. Нужно
--    1.0 * откликов / nullif(count(DISTINCT v.vacancy_id), 0).
-- 4. JOIN (INNER) выкидывает открытые вакансии без откликов (их 6), а они должны быть
--    в знаменателе. Нужно LEFT JOIN.
-- 5. sum(v.salary_from) после JOIN складывает зарплату вакансии столько раз, сколько у неё
--    откликов (13 870 000 вместо 815 000), да и сумма зарплат не имеет смысла. Зарплату
--    лучше считать отдельно через avg по vacancies без JOIN.
--
-- Исправленный запрос:
SELECT v.professional_role,
       count(DISTINCT v.vacancy_id)                         AS vacancies,
       count(r.response_id)                                 AS responses,
       round(1.0 * count(r.response_id)
             / nullif(count(DISTINCT v.vacancy_id), 0), 1)  AS responses_per_vacancy
FROM vacancies v
LEFT JOIN responses r ON v.vacancy_id = r.vacancy_id
WHERE v.closed_at IS NULL
GROUP BY v.professional_role
ORDER BY responses_per_vacancy DESC;

-- зарплата по открытым вакансиям — отдельно, без JOIN:
SELECT professional_role,
       round(avg(salary_from)) AS avg_salary_from
FROM vacancies
WHERE closed_at IS NULL
GROUP BY professional_role
ORDER BY professional_role;

-- Вывод: по открытым вакансиям больше всего откликов на вакансию у аналитика данных (21,5),
-- меньше всего у тестировщика (4,4) — это совпадает с Д2.

-- Какие два правила из лекции защитили бы от этих ошибок при написании запроса:
-- 1. NULL проверяем только через IS NULL / IS NOT NULL, а не через =.
-- 2. Метрики после JOIN считаем по шаблону из лекции: объекты — через count(DISTINCT
--    первичный ключ), доли — как 100.0 * числитель / nullif(знаменатель, 0), а основную
--    таблицу присоединяем через LEFT JOIN, если её строки нельзя терять.
