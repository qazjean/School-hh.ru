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

-- Проверка на NULL в этих колонках
SELECT count(*) FILTER (WHERE experience IS NULL)        AS experience_null,
       count(*) FILTER (WHERE employment IS NULL)        AS employment_null,
       count(*) FILTER (WHERE professional_role IS NULL) AS role_null
FROM vacancies;

-- Вывод: в experience 3 значения, в employment 3, в professional_role 5.
-- Проблем с качеством не нашла: нет одного значения в разных написаниях, лишних пробелов
-- и NULL (проверка дала 0 / 0 / 0), так что можно фильтровать прямо по этим строкам.


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
-- Гипотеза: реально активных может быть меньше. Закрытые вакансии в среднем жили около 41 дня,
-- а 17 из 33 открытых опубликованы больше 3 месяцев назад — возможно, часть просто забыли закрыть.

-- Запрос 3 (проверка гипотезы): открытые вакансии без какой-либо активности после 15 июня
-- (последний отклик в базе — 15 августа, то есть два месяца тишины)
SELECT v.vacancy_id,
       v.vacancy_name,
       v.published_at::date,
       greatest(max(r.created_at), max(m.sent_at), max(c.call_at))::date AS last_activity
FROM vacancies v
LEFT JOIN responses r ON v.vacancy_id = r.vacancy_id
LEFT JOIN messages m  ON v.vacancy_id = m.vacancy_id
LEFT JOIN calls c     ON v.vacancy_id = c.vacancy_id
WHERE v.closed_at IS NULL
  AND v.published_at < DATE '2026-06-15'
GROUP BY v.vacancy_id, v.vacancy_name, v.published_at
HAVING coalesce(greatest(max(r.created_at), max(m.sent_at), max(c.call_at)), v.published_at)
       < DATE '2026-06-15'
ORDER BY last_activity NULLS FIRST;

-- Вывод: гипотеза подтвердилась. У 14 из 33 открытых вакансий после 15 июня не было
-- ни откликов, ни сообщений, ни звонков, а у 5 из них активности не было вообще никогда.
-- То есть реально «живых» вакансий около 19 из 52 (примерно 37%), а не 63,5%. Для руководителя честнее
-- показывать обе цифры: 33 формально открыты, из них активны примерно 19.


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
-- Гипотеза: перекос в сторону аналитиков и разработчиков может быть особенностью самой базы
-- (всего 12 работодателей, половина из них — из Москвы и Петербурга). Проверить на
-- полной выгрузке рынка, а конкуренцию — через отклики на вакансию (это сделано в Д2).
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
-- поэтому count(*) посчитал бы строки вида «вакансия-отклик» (у ТехноБанка 157 вместо 9 вакансий);
-- count(DISTINCT v.vacancy_id) считает каждую вакансию один раз.
-- Во втором запросе пропала «ГринЭнерго» — у неё одна вакансия и ноль откликов. Это именно та
-- компания, про которую HR хотел спросить, почему нет интереса, а в отчёте с INNER JOIN её просто нет.
-- Правило: если нужны все объекты основной таблицы, включая те, у кого ноль, — LEFT JOIN;
-- если нужны только объекты, у которых точно есть пара, — INNER JOIN.

-- Запрос 3: почему у «ГринЭнерго» ноль откликов — смотрим саму вакансию
SELECT v.vacancy_name,
       a.area_name,
       v.salary_from,
       v.published_at::date,
       v.closed_at::date,
       v.closed_at::date - v.published_at::date AS days_open,
       e.is_accredited_it
FROM vacancies v
JOIN employers e ON v.employer_id = e.employer_id
JOIN areas a     ON v.area_id = a.area_id
WHERE e.employer_name = 'ГринЭнерго';

-- Запрос 4 (проверка гипотезы): отклики на вакансию в разрезе
-- IT-аккредитация компании и указана ли зарплата
SELECT e.is_accredited_it,
       v.salary_from IS NOT NULL                           AS has_salary,
       count(DISTINCT v.vacancy_id)                        AS vacancies_cnt,
       count(r.response_id)                                AS responses_cnt,
       round(1.0 * count(r.response_id)
             / nullif(count(DISTINCT v.vacancy_id), 0), 1) AS responses_per_vacancy
FROM vacancies v
JOIN employers e      ON v.employer_id = e.employer_id
LEFT JOIN responses r ON v.vacancy_id = r.vacancy_id
GROUP BY 1, 2
ORDER BY 1, 2;

-- Вывод: единственная вакансия «ГринЭнерго» — стажёр-разработчик в Казани, без зарплаты,
-- провисела всего 28 дней (6 апреля – 4 мая) и уже закрыта. Город и сезон вряд ли причина:
-- у «Казань Диджитал» вакансия, открытая в те же даты, собрала 21 отклик.
-- Гипотеза: кандидатов отпугнули отсутствие зарплаты и то, что компания не IT.
-- Проверка (запрос 4): главный фактор — аккредитация. У неаккредитованных компаний около 4,7–4,8 отклика
-- на вакансию независимо от того, указана зарплата или нет, у аккредитованных — 12,4–14,5.
-- Отсутствие зарплаты снижает отклики заметно меньше (у аккредитованных с зарплатой 14,5, без неё 12,4).
-- Значит, ноль откликов у ГринЭнерго скорее связан с тем, что это не IT-компания, чем с зарплатой.
-- Но точно утверждать это нельзя: неаккредитованных вакансий всего 12. И данные не говорят,
-- были ли у вакансии просмотры (не видели или видели, но не откликнулись) — нужна статистика просмотров.


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

-- Проверка: последняя дата отклика в базе и сколько откликов в августе
SELECT min(created_at)                                       AS first_response_at,
       max(created_at)                                       AS last_response_at,
       count(*) FILTER (WHERE created_at >= DATE '2026-08-01') AS aug_responses
FROM responses;

-- Вывод: максимальная конверсия в июне — 19,5% (118 откликов, 23 приглашения).
-- Доверять этому для планирования нельзя: приглашений в месяц всего от 3 до 23, и разница между
-- месяцами — это несколько приглашений, а данные есть только за 8 месяцев одного года,
-- так что сезонность не проверить.
-- Август неполный: последний отклик в базе — 15.08.2026 08:00, за август всего 41 отклик.
-- Отклики шли каждый день (1–4 в день) до самого 15-го, то есть это обрыв выгрузки, а не спад
-- интереса. За полмесяца 3 приглашения, одно приглашение двигает конверсию на 2,4 п.п.,
-- поэтому 7,3% ненадёжны и август лучше исключить.
-- Гипотеза: свежие отклики ещё не успели дойти до приглашения.

-- Проверка гипотезы: распределение статусов откликов по месяцам
SELECT date_trunc('month', created_at)::date                AS month,
       count(*)                                             AS responses_cnt,
       count(*) FILTER (WHERE status = 'new')               AS new_cnt,
       count(*) FILTER (WHERE status = 'viewed')            AS viewed_cnt,
       count(*) FILTER (WHERE status = 'rejected')          AS rejected_cnt,
       count(*) FILTER (WHERE status = 'invited')           AS invited_cnt,
       round(100.0 * count(*) FILTER (WHERE status IN ('new', 'viewed'))
             / nullif(count(*), 0), 1)                      AS not_processed_pct
FROM responses
GROUP BY 1
ORDER BY 1;

-- Вывод: гипотеза не подтвердилась. Необработанных откликов (new + viewed) в августе 39%,
-- как и в другие месяцы (36–53%), а в статусе new всего 3 из 41 — меньше, чем где-либо.
-- К тому же переписка по откликам в базе идёт до 3 сентября, то есть у августовских откликов
-- было время на ответ. Низкая конверсия августа объясняется другим: отказов 54% (22 из 41) —
-- больше, чем в любом другом месяце, плюс маленькая выборка (3 приглашения).


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
--
-- Что знаем точно: у тестировщиков высокая конверсия, а у аналитиков данных — высокая конкуренция.
-- Гипотезы, почему так: (1) на тестирование откликаются более подходящие кандидаты, (2) требования
-- в вакансиях тестировщиков мягче, (3) работодатели в тестировании быстрее отвечают и приглашают.
-- Проверить: состав кандидатов (опыт, навыки из резюме — в базе есть только resume_id),
-- требования вакансий (key_skills в vacancy_details) и конверсию по уровню опыта отдельно
-- для стажёрских позиций. Последнее можно проверить прямо сейчас:

-- Проверка гипотезы: конверсия только по вакансиям без опыта
SELECT v.professional_role,
       count(DISTINCT v.vacancy_id)                              AS vacancies_cnt,
       count(r.response_id)                                      AS responses_cnt,
       count(r.response_id) FILTER (WHERE r.status = 'invited')  AS invited_cnt,
       round(100.0 * count(r.response_id) FILTER (WHERE r.status = 'invited')
             / nullif(count(r.response_id), 0), 1)               AS conversion_pct
FROM vacancies v
LEFT JOIN responses r ON v.vacancy_id = r.vacancy_id
WHERE v.experience = 'Нет опыта'
GROUP BY v.professional_role
ORDER BY conversion_pct DESC;

-- Вывод: даже среди позиций без опыта у тестировщиков конверсия самая высокая — 43,5%
-- (10 приглашений из 23 откликов), у аналитиков данных — 13,7%. Значит, дело не в том, что
-- у тестировщиков больше позиций без опыта: при одинаковом уровне разрыв сохраняется.
-- Гипотезы 1–3 остаются открытыми, а выборка всё ещё маленькая (4 вакансии), так что делать
-- уверенный вывод пока рано.

-- Проверка гипотез 1 и 3: как работодатели отвечают на отклики и насколько «прицельно»
-- откликаются кандидаты (откликов на одного кандидата внутри направления)
SELECT v.professional_role,
       count(DISTINCT r.response_id)                              AS responses_cnt,
       count(DISTINCT m.response_id)                              AS answered_cnt,
       round(100.0 * count(DISTINCT m.response_id)
             / nullif(count(DISTINCT r.response_id), 0), 1)       AS answered_pct,
       count(DISTINCT r.resume_id)                                AS candidates_cnt,
       round(1.0 * count(DISTINCT r.response_id)
             / nullif(count(DISTINCT r.resume_id), 0), 2)         AS responses_per_candidate
FROM vacancies v
JOIN responses r     ON v.vacancy_id = r.vacancy_id
LEFT JOIN messages m ON r.response_id = m.response_id
                    AND m.sender_role = 'employer'
GROUP BY v.professional_role
ORDER BY answered_pct DESC;

-- Проверка гипотезы 2: требования (key_skills) по направлениям
SELECT DISTINCT v.professional_role,
       d.key_skills
FROM vacancies v
JOIN vacancy_details d ON v.vacancy_id = d.vacancy_id
ORDER BY 1;

-- Вывод по гипотезам:
-- (3) Работодатели — подтверждается: в тестировании работодатель написал кандидату по 100%
--     откликов, в остальных направлениях — 67–78%. То есть там просто никого не оставляют без ответа.
-- (1) Кандидаты — по нашим данным не подтверждается: на одного кандидата везде 1–1,1 отклика,
--     тестировщики откликаются не «прицельнее» других. Опыта и навыков кандидатов в базе нет,
--     поэтому их качество сравнить нельзя.
-- (2) Требования — проверить нельзя: key_skills внутри направления одинаковые у всех вакансий
--     (шаблон), у тестировщиков 3 навыка против 4 у аналитиков — этого мало для вывода.
-- Итог: высокая конверсия тестировщиков лучше всего объясняется активностью работодателей,
-- но вакансий тестировщиков всего 7, так что это пока только предположение.


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
-- 2. count(*) AS vacancies после JOIN считает не вакансии, а строки вида «вакансия-отклик»
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
