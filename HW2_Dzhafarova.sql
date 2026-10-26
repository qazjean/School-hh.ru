-- ============================================================
-- Домашнее задание к лекции «Продвинутый SQL»
-- Школа Аналитиков hh.ru · учебная база hh_school
-- Автор: Джафарова Фарида Зауровна
-- ============================================================
-- Несколько договорённостей, которых я придерживаюсь во всех заданиях.
-- Событие считается коммуникацией по отклику, только если оно ссылается на существующий отклик
-- и его vacancy_id, employer_id и applicant_id совпадают с данными этого отклика. «Первые 7 дней»
-- отсчитываю от responses.created_at: начало окна включается, момент ровно через 7 суток уже нет.
-- ============================================================

SET search_path TO hh_school;

-- ============================================================
-- БЛОК А. Качество и подготовка данных
-- ============================================================

-- ЗАДАНИЕ 1
-- Запрос 1.1а: можно ли связать звонок с откликом (ссылка, совпадение id, время)
WITH calls_ctx AS (
    SELECT c.call_id, c.response_id, c.employer_id, c.applicant_id, c.vacancy_id, c.call_at,
           r.response_id AS r_response_id, r.created_at, r.resume_id,
           r.vacancy_id AS r_vacancy_id, v.employer_id AS r_employer_id
    FROM calls c
    LEFT JOIN responses r ON c.response_id = r.response_id
    LEFT JOIN vacancies v ON r.vacancy_id = v.vacancy_id
)
SELECT
    COUNT(*) FILTER (WHERE response_id IS NULL) AS no_response_id_cnt,
    ARRAY_AGG(call_id ORDER BY call_id) FILTER (WHERE response_id IS NULL) AS no_response_id_ids,
    COUNT(*) FILTER (WHERE response_id IS NOT NULL AND r_response_id IS NULL) AS unknown_response_cnt,
    COUNT(*) FILTER (WHERE r_response_id IS NOT NULL
                       AND (vacancy_id <> r_vacancy_id OR employer_id <> r_employer_id
                            OR applicant_id <> resume_id)) AS ids_mismatch_cnt,
    COUNT(*) FILTER (WHERE call_at < created_at) AS before_response_cnt
FROM calls_ctx;

-- Запрос 1.1б: то же для сообщений
WITH messages_ctx AS (
    SELECT m.message_id, m.employer_id, m.applicant_id, m.vacancy_id, m.sent_at,
           r.response_id AS r_response_id, r.created_at, r.resume_id,
           r.vacancy_id AS r_vacancy_id, v.employer_id AS r_employer_id
    FROM messages m
    LEFT JOIN responses r ON m.response_id = r.response_id
    LEFT JOIN vacancies v ON r.vacancy_id = v.vacancy_id
)
SELECT COUNT(*) FILTER (WHERE r_response_id IS NULL) AS unknown_response_cnt,
       COUNT(*) FILTER (WHERE r_response_id IS NOT NULL
                          AND (vacancy_id <> r_vacancy_id OR employer_id <> r_employer_id
                               OR applicant_id <> resume_id)) AS ids_mismatch_cnt,
       COUNT(*) FILTER (WHERE sent_at < created_at) AS before_response_cnt
FROM messages_ctx;

-- Запрос 1.1в: согласованность значений внутри строки звонка
-- successful -> есть connected и длительность; unsuccessful -> no_answer; error -> technical_error;
-- звонит работодатель -> outbound, кандидат -> inbound
SELECT
    COUNT(*) FILTER (
        WHERE (status = 'successful' AND (call_duration IS NULL OR call_duration <= 0))
           OR (status <> 'successful' AND call_duration IS NOT NULL)
    ) AS status_vs_duration_cnt,
    COUNT(*) FILTER (
        WHERE NOT (
               (status = 'successful' AND 'connected' = ANY(call_tags)
                AND NOT ('no_answer' = ANY(call_tags) OR 'technical_error' = ANY(call_tags)))
            OR (status = 'unsuccessful' AND 'no_answer' = ANY(call_tags)
                AND NOT ('connected' = ANY(call_tags) OR 'technical_error' = ANY(call_tags)))
            OR (status = 'error' AND 'technical_error' = ANY(call_tags)
                AND NOT ('connected' = ANY(call_tags) OR 'no_answer' = ANY(call_tags)))
        )
    ) AS status_vs_tags_cnt,
    COUNT(*) FILTER (
        WHERE NOT ((caller_role = 'employer' AND 'outbound' = ANY(call_tags) AND NOT 'inbound' = ANY(call_tags))
                OR (caller_role = 'applicant' AND 'inbound' = ANY(call_tags) AND NOT 'outbound' = ANY(call_tags)))
    ) AS role_vs_direction_cnt
FROM calls;

-- Запрос 1.1г: пропуски и формат в сообщениях (текст и message_meta)
SELECT COUNT(*) FILTER (WHERE message_text IS NULL OR btrim(message_text) = '') AS empty_text_cnt,
       COUNT(*) FILTER (WHERE NOT (message_meta ? 'channel'
                                   AND message_meta ? 'is_read'
                                   AND message_meta ? 'attachments')) AS missing_meta_keys_cnt,
       COUNT(*) FILTER (WHERE jsonb_typeof(message_meta -> 'is_read') <> 'boolean'
                           OR jsonb_typeof(message_meta -> 'attachments') NOT IN ('array', 'number')) AS wrong_meta_type_cnt
FROM messages;

-- Запрос 1.1д: события, которые противоречат статусу отклика или вакансии
WITH events_ctx AS (
    SELECT 'call' AS src, c.call_id AS event_id, c.caller_role AS role, c.call_at AS event_at,
           r.status, v.closed_at
    FROM calls c
    JOIN responses r ON c.response_id = r.response_id
    JOIN vacancies v ON r.vacancy_id = v.vacancy_id
    UNION ALL
    SELECT 'message', m.message_id, m.sender_role, m.sent_at, r.status, v.closed_at
    FROM messages m
    JOIN responses r ON m.response_id = r.response_id
    JOIN vacancies v ON r.vacancy_id = v.vacancy_id
)
SELECT src,
       COUNT(*) FILTER (WHERE role = 'employer' AND status = 'new') AS employer_event_but_new_cnt,
       ARRAY_AGG(event_id ORDER BY event_id) FILTER (WHERE role = 'employer' AND status = 'new') AS employer_event_but_new_ids,
       COUNT(*) FILTER (WHERE closed_at IS NOT NULL AND event_at > closed_at) AS after_vacancy_closed_cnt,
       ARRAY_AGG(event_id ORDER BY event_id) FILTER (WHERE closed_at IS NOT NULL AND event_at > closed_at) AS after_vacancy_closed_ids
FROM events_ctx
GROUP BY src;

-- Запрос 1.2: длительность успешных звонков (status = successful, есть тег connected, длительность > 0)
WITH valid_durations AS (      -- 1 строка = успешный звонок с интерпретируемой длительностью
    SELECT call_id, call_duration
    FROM calls
    WHERE status = 'successful'
      AND call_duration > 0
      AND 'connected' = ANY(call_tags)
),
p99 AS (
    SELECT PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY call_duration) AS p99_duration
    FROM valid_durations
)
SELECT COUNT(*) AS calls_cnt,
       ROUND(AVG(vd.call_duration), 1) AS avg_duration,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY vd.call_duration) AS median_duration,
       ROUND(MAX(p.p99_duration)::numeric, 1) AS p99_duration,
       COUNT(*) FILTER (WHERE vd.call_duration > p.p99_duration) AS above_p99_cnt,
       ARRAY_AGG(vd.call_id) FILTER (WHERE vd.call_duration > p.p99_duration) AS above_p99_ids,
       ROUND(AVG(vd.call_duration) FILTER (WHERE vd.call_duration <= p.p99_duration), 1) AS avg_without_above_p99
FROM valid_durations vd
CROSS JOIN p99 p;

-- Запрос 1.3: можно ли восстановить отклик для звонков без response_id (по vacancy_id + applicant_id)
SELECT c.call_id,
       COUNT(r.response_id)                          AS matched_responses_cnt,
       MIN(r.response_id)                            AS matched_response_id,
       MIN(r.created_at)::date - c.call_at::date     AS days_call_before_response
FROM calls c
LEFT JOIN responses r ON c.vacancy_id = r.vacancy_id
                     AND c.applicant_id = r.resume_id
WHERE c.response_id IS NULL
GROUP BY c.call_id, c.call_at
ORDER BY c.call_id;

-- Запрос 1.4: какая доля событий работодателя выпадает из окна 7 дней (не ошибка, но важно для охвата)
SELECT 'messages' AS source,
       COUNT(*) AS employer_events_cnt,
       ROUND(100.0 * COUNT(*) FILTER (WHERE m.sent_at >= r.created_at + INTERVAL '7 days') / COUNT(*), 1) AS after_7d_pct
FROM messages m
JOIN responses r ON m.response_id = r.response_id
WHERE m.sender_role = 'employer'
UNION ALL
SELECT 'calls',       COUNT(*),
       ROUND(100.0 * COUNT(*) FILTER (WHERE c.call_at >= r.created_at + INTERVAL '7 days') / COUNT(*), 1)
FROM calls c
JOIN responses r ON c.response_id = r.response_id
WHERE c.caller_role = 'employer';

-- Вывод.
-- Всего я сделала 18 проверок (запросы 1.1а–1.1д и выбросы в 1.2), сработали шесть, но только одна
-- из них затрагивает сам факт коммуникации.
-- Это 8 звонков без response_id (700244–700251): без ссылки на отклик такой звонок невозможно отнести
-- к конкретной истории общения. Остальные проблемы касаются отдельных атрибутов. У двух звонков
-- (700159, 700199) длительность выше 99-го перцентиля. По 20 звонкам и 219 сообщениям работодателя
-- отклик всё ещё числится в статусе new, хотя работодатель с кандидатом уже связывался. Сами события
-- при этом достоверны, а вот статус, судя по всему, обновляется с задержкой, и это стоит помнить
-- в заданиях 4 и 7, где конверсия считается именно по статусу. Ещё 10 звонков и 180 сообщений
-- отправлены уже после закрытия вакансии. Ошибкой я это не считаю, так как после закрытия работодатель
-- вполне может сообщать кандидатам об отказе или доводить до оффера того, кого выбрал, поэтому
-- эти события остаются в анализе. По связям и времени в остальном данные чистые: идентификаторы
-- везде совпадают с откликом, событий раньше отклика нет, статусы звонков согласованы
-- с длительностью и тегами, а в message_meta нет пропущенных ключей.
--
-- Звонки без response_id я разобрала отдельно (запрос 1.3). Каждый из восьми однозначно находит
-- ровно один отклик по паре вакансия + кандидат, но во всех случаях звонок состоялся на 1–5 дней
-- раньше этого отклика. Получается, что ссылка не потерялась: на момент звонка отклика просто ещё
-- не было. Скорее всего, работодатель сам нашёл резюме и позвонил, а кандидат откликнулся уже после
-- разговора. Для истории «после отклика» такие звонки не подходят, поэтому в слой коммуникаций
-- в задании 2 я их не включаю. Подтвердить эту версию можно было бы по источнику контакта,
-- например по признаку «приглашение из поиска по резюме», если он есть в исходной системе.
--
-- Запрос 1.4 показывает, что 31,0% сообщений и 32,1% звонков работодателя приходятся на время позже
-- 7 дней после отклика. Это важное ограничение: окно в неделю отрезает почти
-- треть общения, и все дальнейшие метрики охвата описывают только первую неделю.
--
-- По длительности успешных звонков (запрос 1.2, 181 звонок): средняя 467,3 с, медиана 438 с,
-- 99-й перцентиль 890,4 с, выше него 2 звонка, средняя без них 462,5 с.
-- Значения выше p99 я считаю допустимыми выбросами, а не ошибками. Это 892 и 899 секунд, то есть
-- меньше 15 минут, что для разговора с кандидатом вполне реально. Распределение равномерное от 51
-- до 899 секунд без отрыва верхних значений, и их исключение сдвигает среднее всего на 4,8 секунды.
-- Для типичной длительности звонка я бы взяла медиану, около 7,3 минуты, ведь она устойчива к крайним
-- значениям, и удалять строки из данных при этом не нужно.


-- ============================================================
-- БЛОК Б. История коммуникаций
-- ============================================================

-- ЗАДАНИЕ 2
WITH responses_ctx AS (        -- 1 строка = отклик + работодатель вакансии
    SELECT r.response_id, r.vacancy_id, r.resume_id, r.created_at, r.status,
           v.employer_id, v.professional_role
    FROM responses r
    JOIN vacancies v ON r.vacancy_id = v.vacancy_id
),
calls_7d AS (                  -- 1 строка = звонок работодателя, надёжно связанный с откликом, в первые 7 дней
    SELECT c.response_id, c.employer_id, c.call_id, c.call_at, c.status, c.call_tags
    FROM calls c
    JOIN responses_ctx rc ON c.response_id = rc.response_id
    WHERE c.caller_role = 'employer'
      AND c.vacancy_id   = rc.vacancy_id
      AND c.employer_id  = rc.employer_id
      AND c.applicant_id = rc.resume_id
      AND c.call_at >= rc.created_at
      AND c.call_at <  rc.created_at + INTERVAL '7 days'
),
messages_7d AS (               -- 1 строка = сообщение работодателя, надёжно связанное с откликом, в первые 7 дней
    SELECT m.response_id, m.employer_id, m.message_id, m.sent_at, m.message_meta
    FROM messages m
    JOIN responses_ctx rc ON m.response_id = rc.response_id
    WHERE m.sender_role = 'employer'
      AND m.vacancy_id   = rc.vacancy_id
      AND m.employer_id  = rc.employer_id
      AND m.applicant_id = rc.resume_id
      AND m.sent_at >= rc.created_at
      AND m.sent_at <  rc.created_at + INTERVAL '7 days'
),
events AS (                    -- 1 строка = одна коммуникация работодателя
    SELECT response_id, employer_id, call_id AS event_id, call_at AS event_at, 'call' AS event_type
    FROM calls_7d
    UNION ALL
    SELECT response_id, employer_id, message_id, sent_at, 'message'
    FROM messages_7d
)
SELECT COUNT(*) AS events_cnt,
       COUNT(DISTINCT response_id) AS responses_with_comm_cnt,
       COUNT(*) FILTER (WHERE event_type = 'call') AS calls_cnt,
       COUNT(*) FILTER (WHERE event_type = 'message') AS messages_cnt
FROM events;

-- Запрос 2.2: те же контрольные значения, если считать коммуникацией только состоявшиеся звонки
WITH responses_ctx AS (        -- 1 строка = отклик + работодатель вакансии
    SELECT r.response_id, r.vacancy_id, r.resume_id, r.created_at, r.status,
           v.employer_id, v.professional_role
    FROM responses r
    JOIN vacancies v ON r.vacancy_id = v.vacancy_id
),
calls_7d AS (                  -- 1 строка = звонок работодателя, надёжно связанный с откликом, в первые 7 дней
    SELECT c.response_id, c.employer_id, c.call_id, c.call_at, c.status, c.call_tags
    FROM calls c
    JOIN responses_ctx rc ON c.response_id = rc.response_id
    WHERE c.caller_role = 'employer'
      AND c.vacancy_id   = rc.vacancy_id
      AND c.employer_id  = rc.employer_id
      AND c.applicant_id = rc.resume_id
      AND c.call_at >= rc.created_at
      AND c.call_at <  rc.created_at + INTERVAL '7 days'
),
messages_7d AS (               -- 1 строка = сообщение работодателя, надёжно связанное с откликом, в первые 7 дней
    SELECT m.response_id, m.employer_id, m.message_id, m.sent_at, m.message_meta
    FROM messages m
    JOIN responses_ctx rc ON m.response_id = rc.response_id
    WHERE m.sender_role = 'employer'
      AND m.vacancy_id   = rc.vacancy_id
      AND m.employer_id  = rc.employer_id
      AND m.applicant_id = rc.resume_id
      AND m.sent_at >= rc.created_at
      AND m.sent_at <  rc.created_at + INTERVAL '7 days'
),
events AS (                    -- 1 строка = одна коммуникация работодателя
    SELECT response_id, employer_id, call_id AS event_id, call_at AS event_at, 'call' AS event_type
    FROM calls_7d
    UNION ALL
    SELECT response_id, employer_id, message_id, sent_at, 'message'
    FROM messages_7d
)
SELECT COUNT(*) AS events_cnt,
       COUNT(DISTINCT e.response_id) AS responses_with_comm_cnt,
       COUNT(*) FILTER (WHERE e.event_type = 'call') AS calls_cnt,
       COUNT(*) FILTER (WHERE e.event_type = 'message') AS messages_cnt
FROM events e
LEFT JOIN calls_7d c ON e.event_type = 'call' AND e.event_id = c.call_id
WHERE e.event_type = 'message' OR c.status = 'successful';

-- Вывод: событий 1096, различных откликов с коммуникацией 382, звонков 108, сообщений 988.
-- В слой попали все звонки работодателя, включая недозвоны: попытка связаться тоже говорит о том,
-- что отклик взяли в работу. Исключены только события, которые нельзя надёжно привязать к отклику,
-- и те, что выходят за 7-дневное окно. Уже здесь видно, что основной канал общения — сообщения, и
-- на них приходится 90% всех событий.
-- Включать ли недозвоны — вопрос трактовки, поэтому я проверила и второй вариант (запрос 2.2).
-- Если считать коммуникацией только состоявшийся разговор, получается 1066 событий, 374 отклика
-- с коммуникацией, 78 звонков и 988 сообщений: из слоя уходят 29 недозвонов и 1 звонок с технической
-- ошибкой, и всего у 8 откликов коммуникация пропадает полностью. Основной вариант я оставляю
-- с недозвонами, потому что задача блока — описать реакцию работодателя на отклик, а звонок,
-- на который кандидат не ответил, тоже реакция. Разница небольшая (8 откликов из 382), поэтому
-- дальше все задания считаю по основному варианту.


-- ЗАДАНИЕ 3
-- Шаг 1. Слой уровня события (1 строка = коммуникация, гранулярность как в задании 2)
WITH responses_ctx AS (        -- 1 строка = отклик + работодатель вакансии
    SELECT r.response_id, r.vacancy_id, r.resume_id, r.created_at, r.status,
           v.employer_id, v.professional_role
    FROM responses r
    JOIN vacancies v ON r.vacancy_id = v.vacancy_id
),
calls_7d AS (                  -- 1 строка = звонок работодателя, надёжно связанный с откликом, в первые 7 дней
    SELECT c.response_id, c.employer_id, c.call_id, c.call_at, c.status, c.call_tags
    FROM calls c
    JOIN responses_ctx rc ON c.response_id = rc.response_id
    WHERE c.caller_role = 'employer'
      AND c.vacancy_id   = rc.vacancy_id
      AND c.employer_id  = rc.employer_id
      AND c.applicant_id = rc.resume_id
      AND c.call_at >= rc.created_at
      AND c.call_at <  rc.created_at + INTERVAL '7 days'
),
messages_7d AS (               -- 1 строка = сообщение работодателя, надёжно связанное с откликом, в первые 7 дней
    SELECT m.response_id, m.employer_id, m.message_id, m.sent_at, m.message_meta
    FROM messages m
    JOIN responses_ctx rc ON m.response_id = rc.response_id
    WHERE m.sender_role = 'employer'
      AND m.vacancy_id   = rc.vacancy_id
      AND m.employer_id  = rc.employer_id
      AND m.applicant_id = rc.resume_id
      AND m.sent_at >= rc.created_at
      AND m.sent_at <  rc.created_at + INTERVAL '7 days'
),
events AS (                    -- 1 строка = одна коммуникация работодателя
    SELECT response_id, employer_id, call_id AS event_id, call_at AS event_at, 'call' AS event_type
    FROM calls_7d
    UNION ALL
    SELECT response_id, employer_id, message_id, sent_at, 'message'
    FROM messages_7d
),
timeline AS (                  -- 1 строка = коммуникация (гранулярность events не меняется)
    SELECT e.response_id, e.employer_id, e.event_id, e.event_at, e.event_type,
           ROW_NUMBER() OVER w                                    AS event_num,
           LAG(e.event_at)    OVER w                              AS prev_event_at,
           LEAD(e.event_type) OVER w                              AS next_event_type,
           COUNT(*) OVER (w ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS events_so_far,
           FIRST_VALUE(e.event_type) OVER w                       AS first_event_type,
           LAST_VALUE(e.event_type)  OVER (w ROWS BETWEEN UNBOUNDED PRECEDING
                                               AND UNBOUNDED FOLLOWING) AS last_event_type
    FROM events e
    WINDOW w AS (PARTITION BY e.response_id ORDER BY e.event_at, e.event_type, e.event_id)
),
response_comm AS (             -- 1 строка = отклик с коммуникацией
    SELECT response_id,
           COUNT(*)                                          AS comm_cnt,
           COUNT(*) FILTER (WHERE event_type = 'call')       AS calls_cnt,
           COUNT(*) FILTER (WHERE event_type = 'message')    AS messages_cnt,
           MIN(event_at)                                     AS first_comm_at,
           MAX(event_type) FILTER (WHERE event_num = 1)      AS first_comm_type,
           MAX(event_type) FILTER (WHERE event_num = 2)      AS second_comm_type,
           MAX(last_event_type)                              AS last_comm_type,
           MAX(EXTRACT(EPOCH FROM event_at - prev_event_at) / 3600) AS max_gap_hours
    FROM timeline
    GROUP BY response_id
),
response_mart AS (             -- 1 строка = отклик (все 628, в том числе без коммуникаций)
    SELECT rc.response_id, rc.employer_id, rc.professional_role, rc.status,
           rc.created_at,
           COALESCE(cm.comm_cnt, 0)     AS comm_cnt,
           COALESCE(cm.calls_cnt, 0)    AS calls_cnt,
           COALESCE(cm.messages_cnt, 0) AS messages_cnt,
           cm.first_comm_at,
           cm.first_comm_type, cm.second_comm_type, cm.last_comm_type,
           ROUND((EXTRACT(EPOCH FROM cm.first_comm_at - rc.created_at) / 3600)::numeric, 2) AS hours_to_first_comm,
           ROUND(cm.max_gap_hours::numeric, 2) AS max_gap_hours
    FROM responses_ctx rc
    LEFT JOIN response_comm cm ON rc.response_id = cm.response_id
)
SELECT response_id, employer_id, event_id, event_type, event_at,
       event_num, prev_event_at, next_event_type, events_so_far,
       first_event_type, last_event_type
FROM timeline
ORDER BY response_id, event_num;

-- Шаг 2. Витрина уровня отклика (1 строка = отклик, отклики без коммуникаций сохранены)
WITH responses_ctx AS (        -- 1 строка = отклик + работодатель вакансии
    SELECT r.response_id, r.vacancy_id, r.resume_id, r.created_at, r.status,
           v.employer_id, v.professional_role
    FROM responses r
    JOIN vacancies v ON r.vacancy_id = v.vacancy_id
),
calls_7d AS (                  -- 1 строка = звонок работодателя, надёжно связанный с откликом, в первые 7 дней
    SELECT c.response_id, c.employer_id, c.call_id, c.call_at, c.status, c.call_tags
    FROM calls c
    JOIN responses_ctx rc ON c.response_id = rc.response_id
    WHERE c.caller_role = 'employer'
      AND c.vacancy_id   = rc.vacancy_id
      AND c.employer_id  = rc.employer_id
      AND c.applicant_id = rc.resume_id
      AND c.call_at >= rc.created_at
      AND c.call_at <  rc.created_at + INTERVAL '7 days'
),
messages_7d AS (               -- 1 строка = сообщение работодателя, надёжно связанное с откликом, в первые 7 дней
    SELECT m.response_id, m.employer_id, m.message_id, m.sent_at, m.message_meta
    FROM messages m
    JOIN responses_ctx rc ON m.response_id = rc.response_id
    WHERE m.sender_role = 'employer'
      AND m.vacancy_id   = rc.vacancy_id
      AND m.employer_id  = rc.employer_id
      AND m.applicant_id = rc.resume_id
      AND m.sent_at >= rc.created_at
      AND m.sent_at <  rc.created_at + INTERVAL '7 days'
),
events AS (                    -- 1 строка = одна коммуникация работодателя
    SELECT response_id, employer_id, call_id AS event_id, call_at AS event_at, 'call' AS event_type
    FROM calls_7d
    UNION ALL
    SELECT response_id, employer_id, message_id, sent_at, 'message'
    FROM messages_7d
),
timeline AS (                  -- 1 строка = коммуникация (гранулярность events не меняется)
    SELECT e.response_id, e.employer_id, e.event_id, e.event_at, e.event_type,
           ROW_NUMBER() OVER w                                    AS event_num,
           LAG(e.event_at)    OVER w                              AS prev_event_at,
           LEAD(e.event_type) OVER w                              AS next_event_type,
           COUNT(*) OVER (w ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS events_so_far,
           FIRST_VALUE(e.event_type) OVER w                       AS first_event_type,
           LAST_VALUE(e.event_type)  OVER (w ROWS BETWEEN UNBOUNDED PRECEDING
                                               AND UNBOUNDED FOLLOWING) AS last_event_type
    FROM events e
    WINDOW w AS (PARTITION BY e.response_id ORDER BY e.event_at, e.event_type, e.event_id)
),
response_comm AS (             -- 1 строка = отклик с коммуникацией
    SELECT response_id,
           COUNT(*)                                          AS comm_cnt,
           COUNT(*) FILTER (WHERE event_type = 'call')       AS calls_cnt,
           COUNT(*) FILTER (WHERE event_type = 'message')    AS messages_cnt,
           MIN(event_at)                                     AS first_comm_at,
           MAX(event_type) FILTER (WHERE event_num = 1)      AS first_comm_type,
           MAX(event_type) FILTER (WHERE event_num = 2)      AS second_comm_type,
           MAX(last_event_type)                              AS last_comm_type,
           MAX(EXTRACT(EPOCH FROM event_at - prev_event_at) / 3600) AS max_gap_hours
    FROM timeline
    GROUP BY response_id
),
response_mart AS (             -- 1 строка = отклик (все 628, в том числе без коммуникаций)
    SELECT rc.response_id, rc.employer_id, rc.professional_role, rc.status,
           rc.created_at,
           COALESCE(cm.comm_cnt, 0)     AS comm_cnt,
           COALESCE(cm.calls_cnt, 0)    AS calls_cnt,
           COALESCE(cm.messages_cnt, 0) AS messages_cnt,
           cm.first_comm_at,
           cm.first_comm_type, cm.second_comm_type, cm.last_comm_type,
           ROUND((EXTRACT(EPOCH FROM cm.first_comm_at - rc.created_at) / 3600)::numeric, 2) AS hours_to_first_comm,
           ROUND(cm.max_gap_hours::numeric, 2) AS max_gap_hours
    FROM responses_ctx rc
    LEFT JOIN response_comm cm ON rc.response_id = cm.response_id
)
SELECT response_id, employer_id, professional_role, status,
       comm_cnt, calls_cnt, messages_cnt,
       first_comm_at, first_comm_type, second_comm_type, last_comm_type,
       hours_to_first_comm, max_gap_hours
FROM response_mart
ORDER BY response_id;

-- Контрольные значения по витрине
WITH responses_ctx AS (        -- 1 строка = отклик + работодатель вакансии
    SELECT r.response_id, r.vacancy_id, r.resume_id, r.created_at, r.status,
           v.employer_id, v.professional_role
    FROM responses r
    JOIN vacancies v ON r.vacancy_id = v.vacancy_id
),
calls_7d AS (                  -- 1 строка = звонок работодателя, надёжно связанный с откликом, в первые 7 дней
    SELECT c.response_id, c.employer_id, c.call_id, c.call_at, c.status, c.call_tags
    FROM calls c
    JOIN responses_ctx rc ON c.response_id = rc.response_id
    WHERE c.caller_role = 'employer'
      AND c.vacancy_id   = rc.vacancy_id
      AND c.employer_id  = rc.employer_id
      AND c.applicant_id = rc.resume_id
      AND c.call_at >= rc.created_at
      AND c.call_at <  rc.created_at + INTERVAL '7 days'
),
messages_7d AS (               -- 1 строка = сообщение работодателя, надёжно связанное с откликом, в первые 7 дней
    SELECT m.response_id, m.employer_id, m.message_id, m.sent_at, m.message_meta
    FROM messages m
    JOIN responses_ctx rc ON m.response_id = rc.response_id
    WHERE m.sender_role = 'employer'
      AND m.vacancy_id   = rc.vacancy_id
      AND m.employer_id  = rc.employer_id
      AND m.applicant_id = rc.resume_id
      AND m.sent_at >= rc.created_at
      AND m.sent_at <  rc.created_at + INTERVAL '7 days'
),
events AS (                    -- 1 строка = одна коммуникация работодателя
    SELECT response_id, employer_id, call_id AS event_id, call_at AS event_at, 'call' AS event_type
    FROM calls_7d
    UNION ALL
    SELECT response_id, employer_id, message_id, sent_at, 'message'
    FROM messages_7d
),
timeline AS (                  -- 1 строка = коммуникация (гранулярность events не меняется)
    SELECT e.response_id, e.employer_id, e.event_id, e.event_at, e.event_type,
           ROW_NUMBER() OVER w                                    AS event_num,
           LAG(e.event_at)    OVER w                              AS prev_event_at,
           LEAD(e.event_type) OVER w                              AS next_event_type,
           COUNT(*) OVER (w ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS events_so_far,
           FIRST_VALUE(e.event_type) OVER w                       AS first_event_type,
           LAST_VALUE(e.event_type)  OVER (w ROWS BETWEEN UNBOUNDED PRECEDING
                                               AND UNBOUNDED FOLLOWING) AS last_event_type
    FROM events e
    WINDOW w AS (PARTITION BY e.response_id ORDER BY e.event_at, e.event_type, e.event_id)
),
response_comm AS (             -- 1 строка = отклик с коммуникацией
    SELECT response_id,
           COUNT(*)                                          AS comm_cnt,
           COUNT(*) FILTER (WHERE event_type = 'call')       AS calls_cnt,
           COUNT(*) FILTER (WHERE event_type = 'message')    AS messages_cnt,
           MIN(event_at)                                     AS first_comm_at,
           MAX(event_type) FILTER (WHERE event_num = 1)      AS first_comm_type,
           MAX(event_type) FILTER (WHERE event_num = 2)      AS second_comm_type,
           MAX(last_event_type)                              AS last_comm_type,
           MAX(EXTRACT(EPOCH FROM event_at - prev_event_at) / 3600) AS max_gap_hours
    FROM timeline
    GROUP BY response_id
),
response_mart AS (             -- 1 строка = отклик (все 628, в том числе без коммуникаций)
    SELECT rc.response_id, rc.employer_id, rc.professional_role, rc.status,
           rc.created_at,
           COALESCE(cm.comm_cnt, 0)     AS comm_cnt,
           COALESCE(cm.calls_cnt, 0)    AS calls_cnt,
           COALESCE(cm.messages_cnt, 0) AS messages_cnt,
           cm.first_comm_at,
           cm.first_comm_type, cm.second_comm_type, cm.last_comm_type,
           ROUND((EXTRACT(EPOCH FROM cm.first_comm_at - rc.created_at) / 3600)::numeric, 2) AS hours_to_first_comm,
           ROUND(cm.max_gap_hours::numeric, 2) AS max_gap_hours
    FROM responses_ctx rc
    LEFT JOIN response_comm cm ON rc.response_id = cm.response_id
)
SELECT COUNT(*) AS rows_cnt,
       COUNT(*) FILTER (WHERE comm_cnt > 0) AS with_comm_cnt,
       COUNT(*) FILTER (WHERE comm_cnt = 0) AS without_comm_cnt,
       COUNT(*) FILTER (WHERE first_comm_type = 'message') AS first_message_cnt,
       COUNT(*) FILTER (WHERE first_comm_type = 'call') AS first_call_cnt
FROM response_mart;

-- Вывод: в витрине 628 строк, то есть все отклики на месте; с коммуникацией 382, без коммуникации 246;
-- первой коммуникацией было сообщение в 314 откликах, звонок в 68.
-- Почти 40% откликов (246 из 628) за первую неделю не получили от работодателя никакой реакции.
-- Там, где контакт всё-таки был, работодатель в 82% случаев начинает с сообщения, а звонок первым
-- шагом остаётся редкостью. Похоже, что сообщение служит способом «прощупать» кандидата, а звонок
-- появляется уже на следующих этапах; это стоит проверить по порядку событий внутри отклика.


-- ============================================================
-- БЛОК В. Сравнение работодателей
-- ============================================================

-- ЗАДАНИЕ 4
WITH responses_ctx AS (        -- 1 строка = отклик + работодатель вакансии
    SELECT r.response_id, r.vacancy_id, r.resume_id, r.created_at, r.status,
           v.employer_id, v.professional_role
    FROM responses r
    JOIN vacancies v ON r.vacancy_id = v.vacancy_id
),
calls_7d AS (                  -- 1 строка = звонок работодателя, надёжно связанный с откликом, в первые 7 дней
    SELECT c.response_id, c.employer_id, c.call_id, c.call_at, c.status, c.call_tags
    FROM calls c
    JOIN responses_ctx rc ON c.response_id = rc.response_id
    WHERE c.caller_role = 'employer'
      AND c.vacancy_id   = rc.vacancy_id
      AND c.employer_id  = rc.employer_id
      AND c.applicant_id = rc.resume_id
      AND c.call_at >= rc.created_at
      AND c.call_at <  rc.created_at + INTERVAL '7 days'
),
messages_7d AS (               -- 1 строка = сообщение работодателя, надёжно связанное с откликом, в первые 7 дней
    SELECT m.response_id, m.employer_id, m.message_id, m.sent_at, m.message_meta
    FROM messages m
    JOIN responses_ctx rc ON m.response_id = rc.response_id
    WHERE m.sender_role = 'employer'
      AND m.vacancy_id   = rc.vacancy_id
      AND m.employer_id  = rc.employer_id
      AND m.applicant_id = rc.resume_id
      AND m.sent_at >= rc.created_at
      AND m.sent_at <  rc.created_at + INTERVAL '7 days'
),
events AS (                    -- 1 строка = одна коммуникация работодателя
    SELECT response_id, employer_id, call_id AS event_id, call_at AS event_at, 'call' AS event_type
    FROM calls_7d
    UNION ALL
    SELECT response_id, employer_id, message_id, sent_at, 'message'
    FROM messages_7d
),
timeline AS (                  -- 1 строка = коммуникация (гранулярность events не меняется)
    SELECT e.response_id, e.employer_id, e.event_id, e.event_at, e.event_type,
           ROW_NUMBER() OVER w                                    AS event_num,
           LAG(e.event_at)    OVER w                              AS prev_event_at,
           LEAD(e.event_type) OVER w                              AS next_event_type,
           COUNT(*) OVER (w ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS events_so_far,
           FIRST_VALUE(e.event_type) OVER w                       AS first_event_type,
           LAST_VALUE(e.event_type)  OVER (w ROWS BETWEEN UNBOUNDED PRECEDING
                                               AND UNBOUNDED FOLLOWING) AS last_event_type
    FROM events e
    WINDOW w AS (PARTITION BY e.response_id ORDER BY e.event_at, e.event_type, e.event_id)
),
response_comm AS (             -- 1 строка = отклик с коммуникацией
    SELECT response_id,
           COUNT(*)                                          AS comm_cnt,
           COUNT(*) FILTER (WHERE event_type = 'call')       AS calls_cnt,
           COUNT(*) FILTER (WHERE event_type = 'message')    AS messages_cnt,
           MIN(event_at)                                     AS first_comm_at,
           MAX(event_type) FILTER (WHERE event_num = 1)      AS first_comm_type,
           MAX(event_type) FILTER (WHERE event_num = 2)      AS second_comm_type,
           MAX(last_event_type)                              AS last_comm_type,
           MAX(EXTRACT(EPOCH FROM event_at - prev_event_at) / 3600) AS max_gap_hours
    FROM timeline
    GROUP BY response_id
),
response_mart AS (             -- 1 строка = отклик (все 628, в том числе без коммуникаций)
    SELECT rc.response_id, rc.employer_id, rc.professional_role, rc.status,
           rc.created_at,
           COALESCE(cm.comm_cnt, 0)     AS comm_cnt,
           COALESCE(cm.calls_cnt, 0)    AS calls_cnt,
           COALESCE(cm.messages_cnt, 0) AS messages_cnt,
           cm.first_comm_at,
           cm.first_comm_type, cm.second_comm_type, cm.last_comm_type,
           ROUND((EXTRACT(EPOCH FROM cm.first_comm_at - rc.created_at) / 3600)::numeric, 2) AS hours_to_first_comm,
           ROUND(cm.max_gap_hours::numeric, 2) AS max_gap_hours
    FROM responses_ctx rc
    LEFT JOIN response_comm cm ON rc.response_id = cm.response_id
),
employer_stats AS (            -- 1 строка = направление + работодатель
    SELECT professional_role, employer_id,
           COUNT(*)                                                    AS responses_cnt,
           COUNT(*) FILTER (WHERE comm_cnt > 0)                        AS processed_cnt,
           ROUND(100.0 * COUNT(*) FILTER (WHERE comm_cnt > 0) / COUNT(*), 1) AS processed_pct,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY hours_to_first_comm) AS median_hours_first_comm,
           PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY hours_to_first_comm) AS p90_hours_first_comm,
           ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'invited') / COUNT(*), 1) AS invite_conv_pct
    FROM response_mart
    GROUP BY professional_role, employer_id
    HAVING COUNT(*) >= 8
),
ranked AS (
    SELECT es.*,
           DENSE_RANK() OVER (PARTITION BY professional_role
                              ORDER BY processed_pct DESC, median_hours_first_comm ASC NULLS LAST) AS place
    FROM employer_stats es
)
SELECT professional_role, place, employer_id, responses_cnt, processed_cnt, processed_pct,
       ROUND(median_hours_first_comm::numeric, 1) AS median_hours_first_comm,
       ROUND(p90_hours_first_comm::numeric, 1)    AS p90_hours_first_comm,
       invite_conv_pct
FROM ranked
WHERE place <= 2
ORDER BY professional_role, place, employer_id;

-- Запрос 4.2 (для анализа): все пары с 8+ откликами, без фильтра по месту
WITH responses_ctx AS (        -- 1 строка = отклик + работодатель вакансии
    SELECT r.response_id, r.vacancy_id, r.resume_id, r.created_at, r.status,
           v.employer_id, v.professional_role
    FROM responses r
    JOIN vacancies v ON r.vacancy_id = v.vacancy_id
),
calls_7d AS (                  -- 1 строка = звонок работодателя, надёжно связанный с откликом, в первые 7 дней
    SELECT c.response_id, c.employer_id, c.call_id, c.call_at, c.status, c.call_tags
    FROM calls c
    JOIN responses_ctx rc ON c.response_id = rc.response_id
    WHERE c.caller_role = 'employer'
      AND c.vacancy_id   = rc.vacancy_id
      AND c.employer_id  = rc.employer_id
      AND c.applicant_id = rc.resume_id
      AND c.call_at >= rc.created_at
      AND c.call_at <  rc.created_at + INTERVAL '7 days'
),
messages_7d AS (               -- 1 строка = сообщение работодателя, надёжно связанное с откликом, в первые 7 дней
    SELECT m.response_id, m.employer_id, m.message_id, m.sent_at, m.message_meta
    FROM messages m
    JOIN responses_ctx rc ON m.response_id = rc.response_id
    WHERE m.sender_role = 'employer'
      AND m.vacancy_id   = rc.vacancy_id
      AND m.employer_id  = rc.employer_id
      AND m.applicant_id = rc.resume_id
      AND m.sent_at >= rc.created_at
      AND m.sent_at <  rc.created_at + INTERVAL '7 days'
),
events AS (                    -- 1 строка = одна коммуникация работодателя
    SELECT response_id, employer_id, call_id AS event_id, call_at AS event_at, 'call' AS event_type
    FROM calls_7d
    UNION ALL
    SELECT response_id, employer_id, message_id, sent_at, 'message'
    FROM messages_7d
),
timeline AS (                  -- 1 строка = коммуникация (гранулярность events не меняется)
    SELECT e.response_id, e.employer_id, e.event_id, e.event_at, e.event_type,
           ROW_NUMBER() OVER w                                    AS event_num,
           LAG(e.event_at)    OVER w                              AS prev_event_at,
           LEAD(e.event_type) OVER w                              AS next_event_type,
           COUNT(*) OVER (w ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS events_so_far,
           FIRST_VALUE(e.event_type) OVER w                       AS first_event_type,
           LAST_VALUE(e.event_type)  OVER (w ROWS BETWEEN UNBOUNDED PRECEDING
                                               AND UNBOUNDED FOLLOWING) AS last_event_type
    FROM events e
    WINDOW w AS (PARTITION BY e.response_id ORDER BY e.event_at, e.event_type, e.event_id)
),
response_comm AS (             -- 1 строка = отклик с коммуникацией
    SELECT response_id,
           COUNT(*)                                          AS comm_cnt,
           COUNT(*) FILTER (WHERE event_type = 'call')       AS calls_cnt,
           COUNT(*) FILTER (WHERE event_type = 'message')    AS messages_cnt,
           MIN(event_at)                                     AS first_comm_at,
           MAX(event_type) FILTER (WHERE event_num = 1)      AS first_comm_type,
           MAX(event_type) FILTER (WHERE event_num = 2)      AS second_comm_type,
           MAX(last_event_type)                              AS last_comm_type,
           MAX(EXTRACT(EPOCH FROM event_at - prev_event_at) / 3600) AS max_gap_hours
    FROM timeline
    GROUP BY response_id
),
response_mart AS (             -- 1 строка = отклик (все 628, в том числе без коммуникаций)
    SELECT rc.response_id, rc.employer_id, rc.professional_role, rc.status,
           rc.created_at,
           COALESCE(cm.comm_cnt, 0)     AS comm_cnt,
           COALESCE(cm.calls_cnt, 0)    AS calls_cnt,
           COALESCE(cm.messages_cnt, 0) AS messages_cnt,
           cm.first_comm_at,
           cm.first_comm_type, cm.second_comm_type, cm.last_comm_type,
           ROUND((EXTRACT(EPOCH FROM cm.first_comm_at - rc.created_at) / 3600)::numeric, 2) AS hours_to_first_comm,
           ROUND(cm.max_gap_hours::numeric, 2) AS max_gap_hours
    FROM responses_ctx rc
    LEFT JOIN response_comm cm ON rc.response_id = cm.response_id
)
SELECT professional_role, employer_id,
       COUNT(*) AS responses_cnt,
       ROUND(100.0 * COUNT(*) FILTER (WHERE comm_cnt > 0) / COUNT(*), 1) AS processed_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'invited') / COUNT(*), 1) AS invite_conv_pct
FROM response_mart
GROUP BY professional_role, employer_id
HAVING COUNT(*) >= 8
ORDER BY professional_role, processed_pct DESC;

-- Вывод: в рейтинг попали следующие работодатели (направление — место — employer_id):
--   Аналитик данных:       1 — 109, 2 — 103
--   Дата-инженер:          1 — 106, 2 — 101
--   Продуктовый аналитик:  1 — 103, 2 — 102
--   Разработчик:           1 — 112, 2 — 104
--   Тестировщик:           1 — 107, 2 — 108
-- Даже у лидеров рейтинга кандидат обычно ждёт первого контакта двое-трое суток: медиана у большинства
-- из них от 30 до 76 часов. Заметно быстрее работают только 106 у дата-инженеров (9,7 ч)
-- и 108 у тестировщиков (5,7 ч).
-- Второе место не всегда означает хорошую работу с откликами. У дата-инженеров порог в 8 откликов
-- прошли всего два работодателя, поэтому ТехноБанк (101) оказался вторым, обрабатывая лишь 45,8% откликов.
-- Запрос 4.2 показывает и то, что доля обработки не равна результату. В аналитике данных Мосмаркет (102)
-- отвечает только на 36% откликов, но приглашает больше всех в направлении — 24%. Я думаю, что часть
-- работодателей выходит на связь не со всеми, а только с теми, кого уже готовы пригласить; проверить
-- это можно, сравнив конверсию по откликам с коммуникацией и без неё внутри одного работодателя.
-- Я сделала это в задании 7 (запрос 7.4), и гипотеза не подтвердилась: у Мосмаркета без коммуникации
-- в первую неделю приглашают даже чаще, 22,2% против 16,4%.
-- Отдельно выделяется ТехноБанк в аналитике данных: у него самый большой поток, 115 откликов, и при этом
-- обработано всего 46,1%. Вероятное объяснение — рекрутер просто не успевает разбирать такой объём.
-- Если это так, доля обработки должна проседать в недели с наибольшим числом откликов.


-- ЗАДАНИЕ 5
WITH responses_ctx AS (        -- 1 строка = отклик + работодатель вакансии
    SELECT r.response_id, r.vacancy_id, r.resume_id, r.created_at, r.status,
           v.employer_id, v.professional_role
    FROM responses r
    JOIN vacancies v ON r.vacancy_id = v.vacancy_id
),
calls_7d AS (                  -- 1 строка = звонок работодателя, надёжно связанный с откликом, в первые 7 дней
    SELECT c.response_id, c.employer_id, c.call_id, c.call_at, c.status, c.call_tags
    FROM calls c
    JOIN responses_ctx rc ON c.response_id = rc.response_id
    WHERE c.caller_role = 'employer'
      AND c.vacancy_id   = rc.vacancy_id
      AND c.employer_id  = rc.employer_id
      AND c.applicant_id = rc.resume_id
      AND c.call_at >= rc.created_at
      AND c.call_at <  rc.created_at + INTERVAL '7 days'
),
messages_7d AS (               -- 1 строка = сообщение работодателя, надёжно связанное с откликом, в первые 7 дней
    SELECT m.response_id, m.employer_id, m.message_id, m.sent_at, m.message_meta
    FROM messages m
    JOIN responses_ctx rc ON m.response_id = rc.response_id
    WHERE m.sender_role = 'employer'
      AND m.vacancy_id   = rc.vacancy_id
      AND m.employer_id  = rc.employer_id
      AND m.applicant_id = rc.resume_id
      AND m.sent_at >= rc.created_at
      AND m.sent_at <  rc.created_at + INTERVAL '7 days'
),
events AS (                    -- 1 строка = одна коммуникация работодателя
    SELECT response_id, employer_id, call_id AS event_id, call_at AS event_at, 'call' AS event_type
    FROM calls_7d
    UNION ALL
    SELECT response_id, employer_id, message_id, sent_at, 'message'
    FROM messages_7d
),
dialog_7d AS (                 -- 1 строка = сообщение любой стороны, надёжно связанное с откликом, в первые 7 дней
    SELECT m.response_id, rc.employer_id, m.message_id, m.sender_role, m.sent_at
    FROM messages m
    JOIN responses_ctx rc ON m.response_id = rc.response_id
    WHERE m.vacancy_id   = rc.vacancy_id
      AND m.employer_id  = rc.employer_id
      AND m.applicant_id = rc.resume_id
      AND m.sent_at >= rc.created_at
      AND m.sent_at <  rc.created_at + INTERVAL '7 days'
),
dialog_prev AS (               -- то же + кто и когда писал перед этим
    SELECT d.*,
           LAG(d.sender_role) OVER w AS prev_sender_role,
           LAG(d.sent_at)     OVER w AS prev_sent_at
    FROM dialog_7d d
    WINDOW w AS (PARTITION BY d.response_id ORDER BY d.sent_at, d.message_id)
),
employer_replies AS (          -- 1 строка = ответ работодателя на сообщение кандидата
    SELECT employer_id, response_id, message_id,
           EXTRACT(EPOCH FROM sent_at - prev_sent_at) / 3600 AS reply_hours
    FROM dialog_prev
    WHERE sender_role = 'employer'
      AND prev_sender_role = 'applicant'
)
SELECT employer_id,
       COUNT(*) AS replies_cnt,
       SUM(COUNT(*)) OVER () AS total_replies_cnt,
       ROUND(AVG(reply_hours)::numeric, 2) AS avg_reply_hours,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY reply_hours))::numeric, 2) AS median_reply_hours,
       ROUND((PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY reply_hours))::numeric, 2) AS p90_reply_hours
FROM employer_replies
GROUP BY employer_id
ORDER BY median_reply_hours, employer_id;

-- Вывод: всего найдено 749 ответов работодателя на сообщение кандидата; минимальная медиана
-- у работодателя 107, она равна 3,93 часа.
-- Работодатели в переписке ведут себя очень похоже: медианы у всех одиннадцати укладываются
-- в 3,9–4,9 часа. Среднее везде выше медианы (6–9 ч), а 90-й перцентиль доходит до 13–20 часов,
-- то есть обычно на сообщение отвечают в течение рабочего дня, но заметная часть ответов
-- откладывается на следующий день.
-- Если сопоставить это с заданием 4, получается, что узкое место не в самом диалоге, а в его начале:
-- когда переписка уже идёт, ответ приходит за несколько часов, а первого контакта кандидат ждёт в среднем больше двух суток.


-- ============================================================
-- БЛОК Г. Сложные типы данных
-- ============================================================

-- ЗАДАНИЕ 6.1
WITH responses_ctx AS (        -- 1 строка = отклик + работодатель вакансии
    SELECT r.response_id, r.vacancy_id, r.resume_id, r.created_at, r.status,
           v.employer_id, v.professional_role
    FROM responses r
    JOIN vacancies v ON r.vacancy_id = v.vacancy_id
),
calls_7d AS (                  -- 1 строка = звонок работодателя, надёжно связанный с откликом, в первые 7 дней
    SELECT c.response_id, c.employer_id, c.call_id, c.call_at, c.status, c.call_tags
    FROM calls c
    JOIN responses_ctx rc ON c.response_id = rc.response_id
    WHERE c.caller_role = 'employer'
      AND c.vacancy_id   = rc.vacancy_id
      AND c.employer_id  = rc.employer_id
      AND c.applicant_id = rc.resume_id
      AND c.call_at >= rc.created_at
      AND c.call_at <  rc.created_at + INTERVAL '7 days'
),
messages_7d AS (               -- 1 строка = сообщение работодателя, надёжно связанное с откликом, в первые 7 дней
    SELECT m.response_id, m.employer_id, m.message_id, m.sent_at, m.message_meta
    FROM messages m
    JOIN responses_ctx rc ON m.response_id = rc.response_id
    WHERE m.sender_role = 'employer'
      AND m.vacancy_id   = rc.vacancy_id
      AND m.employer_id  = rc.employer_id
      AND m.applicant_id = rc.resume_id
      AND m.sent_at >= rc.created_at
      AND m.sent_at <  rc.created_at + INTERVAL '7 days'
),
events AS (                    -- 1 строка = одна коммуникация работодателя
    SELECT response_id, employer_id, call_id AS event_id, call_at AS event_at, 'call' AS event_type
    FROM calls_7d
    UNION ALL
    SELECT response_id, employer_id, message_id, sent_at, 'message'
    FROM messages_7d
),
calls_checked AS (             -- 1 строка = звонок работодателя за 7 дней + признак согласованности тегов
    SELECT call_id, status, call_tags,
           (   (status = 'successful'   AND 'connected' = ANY(call_tags)
                AND NOT ('no_answer' = ANY(call_tags) OR 'technical_error' = ANY(call_tags)))
            OR (status = 'unsuccessful' AND 'no_answer' = ANY(call_tags)
                AND NOT ('connected' = ANY(call_tags) OR 'technical_error' = ANY(call_tags)))
            OR (status = 'error'        AND 'technical_error' = ANY(call_tags)
                AND NOT ('connected' = ANY(call_tags) OR 'no_answer' = ANY(call_tags)))
           ) AS is_consistent
    FROM calls_7d
),
valid_calls AS (
    SELECT call_id, call_tags
    FROM calls_checked
    WHERE is_consistent
)
SELECT (SELECT COUNT(*) FROM calls_checked)                         AS calls_7d_cnt,
       (SELECT COUNT(*) FROM calls_checked WHERE NOT is_consistent) AS inconsistent_cnt,
       COUNT(*)                                                     AS valid_calls_cnt,
       COUNT(*) FILTER (WHERE 'screening' = ANY(call_tags))         AS screening_cnt,
       COUNT(*) FILTER (WHERE 'interview' = ANY(call_tags))         AS interview_cnt,
       COUNT(*) FILTER (WHERE 'follow_up' = ANY(call_tags))         AS follow_up_cnt,
       COUNT(*) FILTER (WHERE 'details'   = ANY(call_tags))         AS details_cnt,
       COUNT(*) FILTER (WHERE call_tags && ARRAY['screening', 'interview', 'follow_up', 'details']) AS with_business_tag_cnt,
       ROUND(AVG(CARDINALITY(call_tags)), 2)                        AS avg_tags_per_call
FROM valid_calls;

-- Вывод: звонков работодателя в первые 7 дней 108, противоречий между техническими тегами и статусом
-- нет, поэтому валидны все 108. Тег screening встречается в 25 звонках, interview в 31, follow_up в 29,
-- details в 23; хотя бы один бизнес-тег есть у всех 108 звонков, в среднем на звонок приходится 4,00 тега.
-- Среднее получается ровным потому, что структура тегов одинаковая: voice, исход звонка, направление
-- и ровно один бизнес-тег. Интереснее распределение бизнес-тегов. Чаще всего в первую неделю звонят
-- с тегом interview (29%), а первичный скрининг встречается реже (23%). Получается, что звонок
-- работодателя на этом этапе чаще связан уже с собеседованием, чем со знакомством с кандидатом.


-- ЗАДАНИЕ 6.2
WITH responses_ctx AS (        -- 1 строка = отклик + работодатель вакансии
    SELECT r.response_id, r.vacancy_id, r.resume_id, r.created_at, r.status,
           v.employer_id, v.professional_role
    FROM responses r
    JOIN vacancies v ON r.vacancy_id = v.vacancy_id
),
calls_7d AS (                  -- 1 строка = звонок работодателя, надёжно связанный с откликом, в первые 7 дней
    SELECT c.response_id, c.employer_id, c.call_id, c.call_at, c.status, c.call_tags
    FROM calls c
    JOIN responses_ctx rc ON c.response_id = rc.response_id
    WHERE c.caller_role = 'employer'
      AND c.vacancy_id   = rc.vacancy_id
      AND c.employer_id  = rc.employer_id
      AND c.applicant_id = rc.resume_id
      AND c.call_at >= rc.created_at
      AND c.call_at <  rc.created_at + INTERVAL '7 days'
),
messages_7d AS (               -- 1 строка = сообщение работодателя, надёжно связанное с откликом, в первые 7 дней
    SELECT m.response_id, m.employer_id, m.message_id, m.sent_at, m.message_meta
    FROM messages m
    JOIN responses_ctx rc ON m.response_id = rc.response_id
    WHERE m.sender_role = 'employer'
      AND m.vacancy_id   = rc.vacancy_id
      AND m.employer_id  = rc.employer_id
      AND m.applicant_id = rc.resume_id
      AND m.sent_at >= rc.created_at
      AND m.sent_at <  rc.created_at + INTERVAL '7 days'
),
events AS (                    -- 1 строка = одна коммуникация работодателя
    SELECT response_id, employer_id, call_id AS event_id, call_at AS event_at, 'call' AS event_type
    FROM calls_7d
    UNION ALL
    SELECT response_id, employer_id, message_id, sent_at, 'message'
    FROM messages_7d
),
messages_meta AS (             -- 1 строка = сообщение работодателя за 7 дней + поля из JSON
    SELECT message_id,
           COALESCE(message_meta ->> 'channel', 'нет канала')            AS channel,
           message_meta ? 'is_read'
               AND jsonb_typeof(message_meta -> 'is_read') = 'boolean'   AS has_is_read,
           CASE WHEN jsonb_typeof(message_meta -> 'is_read') = 'boolean'
                THEN (message_meta ->> 'is_read')::boolean END          AS is_read,
           CASE jsonb_typeof(message_meta -> 'attachments')
                WHEN 'array'  THEN jsonb_array_length(message_meta -> 'attachments')
                WHEN 'number' THEN (message_meta ->> 'attachments')::integer
           END                                                          AS attachments_cnt
    FROM messages_7d
)
SELECT channel,
       COUNT(*) AS messages_cnt,
       COUNT(*) FILTER (WHERE has_is_read) AS with_is_read_cnt,
       COUNT(*) FILTER (WHERE is_read = false) AS unread_cnt,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_read = false)
             / NULLIF(COUNT(*) FILTER (WHERE has_is_read), 0), 1) AS unread_pct,
       COUNT(*) FILTER (WHERE attachments_cnt > 0) AS with_attachment_cnt,
       ROUND(100.0 * COUNT(*) FILTER (WHERE attachments_cnt > 0) / COUNT(*), 1) AS with_attachment_pct
FROM messages_meta
GROUP BY channel
ORDER BY messages_cnt DESC;

-- Вывод:
--   web: 628 сообщений, признак прочтения есть у 628, непрочитанных 52 (8,3%), с вложением 25 (4,0%);
--  mobile_app: 360 сообщений, признак прочтения есть у 360, непрочитанных 36 (10,0%), с вложением 14 (3,9%).
-- Сообщений без канала в данных нет, поэтому отдельная группа не понадобилась, а признак прочтения
-- заполнен у всех сообщений. В мобильном приложении непрочитанных чуть больше, чем в вебе
-- (10,0% против 8,3%), но на 360 сообщениях эта разница соответствует примерно шести сообщениям,
-- так что говорить о худшей доставке через приложение пока рано. Вложения работодатели прикладывают
-- редко, примерно к каждому двадцать пятому сообщению, и в обоих каналах одинаково.


-- ============================================================
-- БЛОК Д. Самостоятельное исследование
-- ============================================================

-- ЗАДАНИЕ 7
-- Гипотеза 1. По откликам, которые закончились приглашением, работодатель выходит на связь быстрее:
-- медиана времени до первой коммуникации у них ниже, а доля первых контактов в первые сутки выше.
-- Гипотеза 2. Приглашённые отклики отличаются характером контакта: в них чаще есть успешный звонок,
-- то есть живой разговор, и чаще идёт двусторонний диалог, когда кандидат сам отвечает работодателю.
-- Для проверки я сравниваю несколько характеристик, относящихся к трём аспектам коммуникации:
-- скорость (время до первого контакта, доля контактов за 24 часа), канал и исход контакта (доля
-- успешных звонков, доля откликов, где использовались оба канала) и интенсивность общения
-- (число коммуникаций и доля откликов, где писал сам кандидат). Новые расчёты, которых не было
-- в заданиях 1–6, — доля успешных звонков, вовлечённость кандидата и обратный разрез: конверсия
-- в приглашение в зависимости от скорости первого контакта и от исхода звонков.
-- Отклики я делю на три группы: приглашение, отказ и «в работе» (new и viewed). Отказ и ещё не
-- принятое решение лучше не смешивать, иначе сравнение с приглашёнными будет размытым.

-- Запрос 7.1: профиль коммуникаций по группам
WITH responses_ctx AS (        -- 1 строка = отклик + работодатель вакансии
    SELECT r.response_id, r.vacancy_id, r.resume_id, r.created_at, r.status,
           v.employer_id, v.professional_role
    FROM responses r
    JOIN vacancies v ON r.vacancy_id = v.vacancy_id
),
calls_7d AS (                  -- 1 строка = звонок работодателя, надёжно связанный с откликом, в первые 7 дней
    SELECT c.response_id, c.employer_id, c.call_id, c.call_at, c.status, c.call_tags
    FROM calls c
    JOIN responses_ctx rc ON c.response_id = rc.response_id
    WHERE c.caller_role = 'employer'
      AND c.vacancy_id   = rc.vacancy_id
      AND c.employer_id  = rc.employer_id
      AND c.applicant_id = rc.resume_id
      AND c.call_at >= rc.created_at
      AND c.call_at <  rc.created_at + INTERVAL '7 days'
),
messages_7d AS (               -- 1 строка = сообщение работодателя, надёжно связанное с откликом, в первые 7 дней
    SELECT m.response_id, m.employer_id, m.message_id, m.sent_at, m.message_meta
    FROM messages m
    JOIN responses_ctx rc ON m.response_id = rc.response_id
    WHERE m.sender_role = 'employer'
      AND m.vacancy_id   = rc.vacancy_id
      AND m.employer_id  = rc.employer_id
      AND m.applicant_id = rc.resume_id
      AND m.sent_at >= rc.created_at
      AND m.sent_at <  rc.created_at + INTERVAL '7 days'
),
events AS (                    -- 1 строка = одна коммуникация работодателя
    SELECT response_id, employer_id, call_id AS event_id, call_at AS event_at, 'call' AS event_type
    FROM calls_7d
    UNION ALL
    SELECT response_id, employer_id, message_id, sent_at, 'message'
    FROM messages_7d
),
timeline AS (                  -- 1 строка = коммуникация (гранулярность events не меняется)
    SELECT e.response_id, e.employer_id, e.event_id, e.event_at, e.event_type,
           ROW_NUMBER() OVER w                                    AS event_num,
           LAG(e.event_at)    OVER w                              AS prev_event_at,
           LEAD(e.event_type) OVER w                              AS next_event_type,
           COUNT(*) OVER (w ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS events_so_far,
           FIRST_VALUE(e.event_type) OVER w                       AS first_event_type,
           LAST_VALUE(e.event_type)  OVER (w ROWS BETWEEN UNBOUNDED PRECEDING
                                               AND UNBOUNDED FOLLOWING) AS last_event_type
    FROM events e
    WINDOW w AS (PARTITION BY e.response_id ORDER BY e.event_at, e.event_type, e.event_id)
),
response_comm AS (             -- 1 строка = отклик с коммуникацией
    SELECT response_id,
           COUNT(*)                                          AS comm_cnt,
           COUNT(*) FILTER (WHERE event_type = 'call')       AS calls_cnt,
           COUNT(*) FILTER (WHERE event_type = 'message')    AS messages_cnt,
           MIN(event_at)                                     AS first_comm_at,
           MAX(event_type) FILTER (WHERE event_num = 1)      AS first_comm_type,
           MAX(event_type) FILTER (WHERE event_num = 2)      AS second_comm_type,
           MAX(last_event_type)                              AS last_comm_type,
           MAX(EXTRACT(EPOCH FROM event_at - prev_event_at) / 3600) AS max_gap_hours
    FROM timeline
    GROUP BY response_id
),
response_mart AS (             -- 1 строка = отклик (все 628, в том числе без коммуникаций)
    SELECT rc.response_id, rc.employer_id, rc.professional_role, rc.status,
           rc.created_at,
           COALESCE(cm.comm_cnt, 0)     AS comm_cnt,
           COALESCE(cm.calls_cnt, 0)    AS calls_cnt,
           COALESCE(cm.messages_cnt, 0) AS messages_cnt,
           cm.first_comm_at,
           cm.first_comm_type, cm.second_comm_type, cm.last_comm_type,
           ROUND((EXTRACT(EPOCH FROM cm.first_comm_at - rc.created_at) / 3600)::numeric, 2) AS hours_to_first_comm,
           ROUND(cm.max_gap_hours::numeric, 2) AS max_gap_hours
    FROM responses_ctx rc
    LEFT JOIN response_comm cm ON rc.response_id = cm.response_id
),
call_outcome AS (              -- 1 строка = отклик со звонками работодателя за 7 дней
    SELECT response_id,
           COUNT(*) FILTER (WHERE status = 'successful') AS successful_calls_cnt
    FROM calls_7d
    GROUP BY response_id
),
candidate_msgs AS (            -- 1 строка = отклик, где кандидат писал в первые 7 дней (новый расчёт)
    SELECT m.response_id, COUNT(*) AS candidate_msgs_cnt
    FROM messages m
    JOIN responses_ctx rc ON m.response_id = rc.response_id
    WHERE m.sender_role = 'applicant'
      AND m.sent_at >= rc.created_at
      AND m.sent_at <  rc.created_at + INTERVAL '7 days'
    GROUP BY m.response_id
),
groups AS (                    -- 1 строка = отклик + группа сравнения
    SELECT rm.response_id, rm.comm_cnt, rm.calls_cnt, rm.messages_cnt, rm.hours_to_first_comm,
           CASE WHEN rm.status = 'invited'  THEN '1. приглашение'
                WHEN rm.status = 'rejected' THEN '2. отказ'
                ELSE '3. в работе (new/viewed)'
           END                                         AS response_group,
           COALESCE(co.successful_calls_cnt, 0)        AS successful_calls_cnt,
           COALESCE(cm.candidate_msgs_cnt, 0)          AS candidate_msgs_cnt
    FROM response_mart rm
    LEFT JOIN call_outcome   co ON rm.response_id = co.response_id
    LEFT JOIN candidate_msgs cm ON rm.response_id = cm.response_id
)
SELECT response_group,
       COUNT(*)                                                            AS responses_cnt,
       COUNT(*) FILTER (WHERE comm_cnt > 0)                                AS with_comm_cnt,
       ROUND(100.0 * COUNT(*) FILTER (WHERE comm_cnt > 0) / COUNT(*), 1)   AS with_comm_pct,
       -- аспект 1: скорость
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY hours_to_first_comm))::numeric, 1) AS median_hours_first_comm,
       ROUND(100.0 * COUNT(*) FILTER (WHERE hours_to_first_comm <= 24)
             / NULLIF(COUNT(*) FILTER (WHERE comm_cnt > 0), 0), 1)         AS first_comm_24h_pct,
       -- аспект 2: канал и результат контакта
       ROUND(100.0 * COUNT(*) FILTER (WHERE successful_calls_cnt > 0)
             / NULLIF(COUNT(*) FILTER (WHERE comm_cnt > 0), 0), 1)         AS successful_call_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE calls_cnt > 0 AND messages_cnt > 0)
             / NULLIF(COUNT(*) FILTER (WHERE comm_cnt > 0), 0), 1)         AS both_channels_pct,
       -- аспект 3: интенсивность и вовлечённость кандидата
       ROUND(AVG(comm_cnt) FILTER (WHERE comm_cnt > 0), 2)                 AS avg_comm_per_response,
       ROUND(100.0 * COUNT(*) FILTER (WHERE candidate_msgs_cnt > 0) / COUNT(*), 1) AS candidate_wrote_pct
FROM groups
GROUP BY response_group
ORDER BY response_group;

-- Запрос 7.2: обратный разрез — конверсия в приглашение по скорости первого контакта и по исходу звонков
WITH responses_ctx AS (        -- 1 строка = отклик + работодатель вакансии
    SELECT r.response_id, r.vacancy_id, r.resume_id, r.created_at, r.status,
           v.employer_id, v.professional_role
    FROM responses r
    JOIN vacancies v ON r.vacancy_id = v.vacancy_id
),
calls_7d AS (                  -- 1 строка = звонок работодателя, надёжно связанный с откликом, в первые 7 дней
    SELECT c.response_id, c.employer_id, c.call_id, c.call_at, c.status, c.call_tags
    FROM calls c
    JOIN responses_ctx rc ON c.response_id = rc.response_id
    WHERE c.caller_role = 'employer'
      AND c.vacancy_id   = rc.vacancy_id
      AND c.employer_id  = rc.employer_id
      AND c.applicant_id = rc.resume_id
      AND c.call_at >= rc.created_at
      AND c.call_at <  rc.created_at + INTERVAL '7 days'
),
messages_7d AS (               -- 1 строка = сообщение работодателя, надёжно связанное с откликом, в первые 7 дней
    SELECT m.response_id, m.employer_id, m.message_id, m.sent_at, m.message_meta
    FROM messages m
    JOIN responses_ctx rc ON m.response_id = rc.response_id
    WHERE m.sender_role = 'employer'
      AND m.vacancy_id   = rc.vacancy_id
      AND m.employer_id  = rc.employer_id
      AND m.applicant_id = rc.resume_id
      AND m.sent_at >= rc.created_at
      AND m.sent_at <  rc.created_at + INTERVAL '7 days'
),
events AS (                    -- 1 строка = одна коммуникация работодателя
    SELECT response_id, employer_id, call_id AS event_id, call_at AS event_at, 'call' AS event_type
    FROM calls_7d
    UNION ALL
    SELECT response_id, employer_id, message_id, sent_at, 'message'
    FROM messages_7d
),
timeline AS (                  -- 1 строка = коммуникация (гранулярность events не меняется)
    SELECT e.response_id, e.employer_id, e.event_id, e.event_at, e.event_type,
           ROW_NUMBER() OVER w                                    AS event_num,
           LAG(e.event_at)    OVER w                              AS prev_event_at,
           LEAD(e.event_type) OVER w                              AS next_event_type,
           COUNT(*) OVER (w ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS events_so_far,
           FIRST_VALUE(e.event_type) OVER w                       AS first_event_type,
           LAST_VALUE(e.event_type)  OVER (w ROWS BETWEEN UNBOUNDED PRECEDING
                                               AND UNBOUNDED FOLLOWING) AS last_event_type
    FROM events e
    WINDOW w AS (PARTITION BY e.response_id ORDER BY e.event_at, e.event_type, e.event_id)
),
response_comm AS (             -- 1 строка = отклик с коммуникацией
    SELECT response_id,
           COUNT(*)                                          AS comm_cnt,
           COUNT(*) FILTER (WHERE event_type = 'call')       AS calls_cnt,
           COUNT(*) FILTER (WHERE event_type = 'message')    AS messages_cnt,
           MIN(event_at)                                     AS first_comm_at,
           MAX(event_type) FILTER (WHERE event_num = 1)      AS first_comm_type,
           MAX(event_type) FILTER (WHERE event_num = 2)      AS second_comm_type,
           MAX(last_event_type)                              AS last_comm_type,
           MAX(EXTRACT(EPOCH FROM event_at - prev_event_at) / 3600) AS max_gap_hours
    FROM timeline
    GROUP BY response_id
),
response_mart AS (             -- 1 строка = отклик (все 628, в том числе без коммуникаций)
    SELECT rc.response_id, rc.employer_id, rc.professional_role, rc.status,
           rc.created_at,
           COALESCE(cm.comm_cnt, 0)     AS comm_cnt,
           COALESCE(cm.calls_cnt, 0)    AS calls_cnt,
           COALESCE(cm.messages_cnt, 0) AS messages_cnt,
           cm.first_comm_at,
           cm.first_comm_type, cm.second_comm_type, cm.last_comm_type,
           ROUND((EXTRACT(EPOCH FROM cm.first_comm_at - rc.created_at) / 3600)::numeric, 2) AS hours_to_first_comm,
           ROUND(cm.max_gap_hours::numeric, 2) AS max_gap_hours
    FROM responses_ctx rc
    LEFT JOIN response_comm cm ON rc.response_id = cm.response_id
),
call_outcome AS (
    SELECT response_id,
           COUNT(*) FILTER (WHERE status = 'successful') AS successful_calls_cnt
    FROM calls_7d
    GROUP BY response_id
),
segments AS (                  -- 1 строка = отклик + сегменты по скорости и по исходу звонков
    SELECT rm.response_id, rm.status,
           CASE WHEN rm.comm_cnt = 0               THEN '4. нет коммуникации'
                WHEN rm.hours_to_first_comm <= 24  THEN '1. до 24 ч'
                WHEN rm.hours_to_first_comm <= 72  THEN '2. 24–72 ч'
                ELSE '3. больше 72 ч'
           END AS speed_segment,
           CASE WHEN rm.calls_cnt = 0                    THEN NULL
                WHEN co.successful_calls_cnt > 0         THEN 'был успешный звонок'
                ELSE 'звонки без дозвона'
           END AS call_segment
    FROM response_mart rm
    LEFT JOIN call_outcome co ON rm.response_id = co.response_id
)
SELECT 'скорость первого контакта' AS cut, speed_segment AS segment,
       COUNT(*) AS responses_cnt,
       ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'invited') / COUNT(*), 1) AS invite_conv_pct
FROM segments
GROUP BY speed_segment
UNION ALL
SELECT 'исход звонков', call_segment,
       COUNT(*),
       ROUND(100.0 * COUNT(*) FILTER (WHERE status = 'invited') / COUNT(*), 1)
FROM segments
WHERE call_segment IS NOT NULL
GROUP BY call_segment
ORDER BY cut, segment;

-- Запрос 7.3: проверка ограничения — у скольких откликов нет никакой коммуникации работодателя за всё время
SELECT r.status,
       COUNT(*) AS responses_cnt,
       COUNT(*) FILTER (
           WHERE NOT EXISTS (SELECT 1 FROM messages m
                             WHERE m.response_id = r.response_id AND m.sender_role = 'employer')
             AND NOT EXISTS (SELECT 1 FROM calls c
                             WHERE c.response_id = r.response_id AND c.caller_role = 'employer')
       ) AS no_employer_contact_ever_cnt
FROM responses r
GROUP BY r.status
ORDER BY r.status;

-- Запрос 7.4: проверка внутри работодателя — конверсия по откликам с коммуникацией и без неё
-- (заодно проверяю гипотезу из задания 4 о том, что работодатели связываются только с теми, кого пригласят)
WITH responses_ctx AS (        -- 1 строка = отклик + работодатель вакансии
    SELECT r.response_id, r.vacancy_id, r.resume_id, r.created_at, r.status,
           v.employer_id, v.professional_role
    FROM responses r
    JOIN vacancies v ON r.vacancy_id = v.vacancy_id
),
calls_7d AS (                  -- 1 строка = звонок работодателя, надёжно связанный с откликом, в первые 7 дней
    SELECT c.response_id, c.employer_id, c.call_id, c.call_at, c.status, c.call_tags
    FROM calls c
    JOIN responses_ctx rc ON c.response_id = rc.response_id
    WHERE c.caller_role = 'employer'
      AND c.vacancy_id   = rc.vacancy_id
      AND c.employer_id  = rc.employer_id
      AND c.applicant_id = rc.resume_id
      AND c.call_at >= rc.created_at
      AND c.call_at <  rc.created_at + INTERVAL '7 days'
),
messages_7d AS (               -- 1 строка = сообщение работодателя, надёжно связанное с откликом, в первые 7 дней
    SELECT m.response_id, m.employer_id, m.message_id, m.sent_at, m.message_meta
    FROM messages m
    JOIN responses_ctx rc ON m.response_id = rc.response_id
    WHERE m.sender_role = 'employer'
      AND m.vacancy_id   = rc.vacancy_id
      AND m.employer_id  = rc.employer_id
      AND m.applicant_id = rc.resume_id
      AND m.sent_at >= rc.created_at
      AND m.sent_at <  rc.created_at + INTERVAL '7 days'
),
events AS (                    -- 1 строка = одна коммуникация работодателя
    SELECT response_id, employer_id, call_id AS event_id, call_at AS event_at, 'call' AS event_type
    FROM calls_7d
    UNION ALL
    SELECT response_id, employer_id, message_id, sent_at, 'message'
    FROM messages_7d
),
timeline AS (                  -- 1 строка = коммуникация (гранулярность events не меняется)
    SELECT e.response_id, e.employer_id, e.event_id, e.event_at, e.event_type,
           ROW_NUMBER() OVER w                                    AS event_num,
           LAG(e.event_at)    OVER w                              AS prev_event_at,
           LEAD(e.event_type) OVER w                              AS next_event_type,
           COUNT(*) OVER (w ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS events_so_far,
           FIRST_VALUE(e.event_type) OVER w                       AS first_event_type,
           LAST_VALUE(e.event_type)  OVER (w ROWS BETWEEN UNBOUNDED PRECEDING
                                               AND UNBOUNDED FOLLOWING) AS last_event_type
    FROM events e
    WINDOW w AS (PARTITION BY e.response_id ORDER BY e.event_at, e.event_type, e.event_id)
),
response_comm AS (             -- 1 строка = отклик с коммуникацией
    SELECT response_id,
           COUNT(*)                                          AS comm_cnt,
           COUNT(*) FILTER (WHERE event_type = 'call')       AS calls_cnt,
           COUNT(*) FILTER (WHERE event_type = 'message')    AS messages_cnt,
           MIN(event_at)                                     AS first_comm_at,
           MAX(event_type) FILTER (WHERE event_num = 1)      AS first_comm_type,
           MAX(event_type) FILTER (WHERE event_num = 2)      AS second_comm_type,
           MAX(last_event_type)                              AS last_comm_type,
           MAX(EXTRACT(EPOCH FROM event_at - prev_event_at) / 3600) AS max_gap_hours
    FROM timeline
    GROUP BY response_id
),
response_mart AS (             -- 1 строка = отклик (все 628, в том числе без коммуникаций)
    SELECT rc.response_id, rc.employer_id, rc.professional_role, rc.status,
           rc.created_at,
           COALESCE(cm.comm_cnt, 0)     AS comm_cnt,
           COALESCE(cm.calls_cnt, 0)    AS calls_cnt,
           COALESCE(cm.messages_cnt, 0) AS messages_cnt,
           cm.first_comm_at,
           cm.first_comm_type, cm.second_comm_type, cm.last_comm_type,
           ROUND((EXTRACT(EPOCH FROM cm.first_comm_at - rc.created_at) / 3600)::numeric, 2) AS hours_to_first_comm,
           ROUND(cm.max_gap_hours::numeric, 2) AS max_gap_hours
    FROM responses_ctx rc
    LEFT JOIN response_comm cm ON rc.response_id = cm.response_id
)
SELECT employer_id,
       COUNT(*) FILTER (WHERE comm_cnt = 0) AS no_comm_cnt,
       ROUND(100.0 * COUNT(*) FILTER (WHERE comm_cnt = 0 AND status = 'invited')
             / NULLIF(COUNT(*) FILTER (WHERE comm_cnt = 0), 0), 1) AS no_comm_conv_pct,
       COUNT(*) FILTER (WHERE comm_cnt > 0) AS with_comm_cnt,
       ROUND(100.0 * COUNT(*) FILTER (WHERE comm_cnt > 0 AND status = 'invited')
             / NULLIF(COUNT(*) FILTER (WHERE comm_cnt > 0), 0), 1) AS with_comm_conv_pct
FROM response_mart
GROUP BY employer_id
ORDER BY employer_id;

-- Вывод по гипотезе 1: она не подтверждается.
-- У приглашённых (92 отклика, из них 54 с коммуникацией) медиана до первого контакта 51,1 часа,
-- а в первые сутки на связь вышли в 33,3% случаев. У отказов (260 и 157) это 54,3 часа и 33,8%,
-- у откликов в работе (276 и 171) — 55,0 часа и 29,8%. Разница в три-четыре часа при медиане больше
-- двух суток ничего не значит. Обратный разрез это подтверждает: конверсия в приглашение почти
-- не зависит от скорости — 14,8% при контакте в первые сутки (122 отклика), 13,6% при 24–72 часах (103)
-- и 14,0% при ожидании дольше трёх суток (157).
--
-- Вывод по гипотезе 2: по звонкам данных недостаточно, по диалогу не подтверждается.
-- Успешный звонок есть у 22,2% приглашённых против 16,6% отказов, и среди откликов со звонками
-- конверсия при дозвоне выше: 15,8% (76 откликов) против 11,1% (27). Направление совпадает
-- с гипотезой, но у откликов в работе доля успешных звонков такая же, как у приглашённых (22,2%),
-- а в группе без дозвона всего 27 откликов, и разница в конверсии соответствует одному-двум
-- приглашениям. Делать на этом вывод я бы не стала. Диалог же у приглашённых ничем не выделяется:
-- кандидат писал в 51,1% случаев против 55,8% и 55,1%, коммуникаций в среднем 2,78 против 2,92 и 2,85,
-- а оба канала использовались в 14,8% откликов против 17,2% и 17,5%.
--
-- Самое интересное обнаружилось при проверке ограничений. У откликов, по которым за первую неделю
-- не было никакой коммуникации, конверсия 15,4% (246 откликов), то есть не ниже, чем у остальных.
-- А запрос 7.3 показывает, что у 19 из 92 приглашённых (21%) в базе вообще нет ни одного звонка
-- или сообщения от работодателя. Значит, приглашение фиксируется независимо от той коммуникации,
-- которую мы видим: вероятно, часть общения идёт через каналы, которых нет в этих таблицах
-- (почта, мессенджеры, звонки с личного телефона), либо статус выставляется отдельно от общения.
-- Поэтому по имеющимся данным связь коммуникации с приглашением почти не прослеживается.
--
-- Можно возразить, что такая картина получается из-за разного набора работодателей в группах, поэтому
-- я сравнила отклики с коммуникацией и без неё внутри каждого работодателя (запрос 7.4). Если брать
-- только тех, у кого в обеих группах хотя бы по 20 откликов, у четырёх из пяти конверсия без
-- коммуникации даже выше: у ТехноБанка (101) 12,3% против 9,3%, у Мосмаркета (102) 22,2% против 16,4%,
-- у DataWave (103) 14,3% против 10,1%, у УралСофта (106) 17,1% против 9,1%. Обратная картина только
-- у 110: 4,5% без коммуникации против 15,6% с ней. Значит, дело не в составе работодателей,
-- и вывод о том, что приглашения во многом идут мимо наблюдаемых каналов, становится надёжнее.
-- Заодно не подтвердилась гипотеза из задания 4: Мосмаркет не ограничивается контактом только
-- с теми, кого собирается пригласить, иначе среди откликов без коммуникации приглашений почти не было бы.


-- ЗАДАНИЕ 8. Итог исследования
-- После отклика работодатели общаются с кандидатами в основном через сообщения: из 1096 событий
-- первой недели 988 приходятся на переписку (задание 2). С сообщения чаще всего и начинается
-- общение, так было в 314 из 382 откликов с коммуникацией (задание 3). При этом 246 из 628 откликов,
-- почти 40%, за первую неделю вообще не получили реакции, а там, где контакт состоялся, его обычно
-- приходится ждать двое-трое суток (задание 4).
-- Когда же переписка начата, работодатели отвечают быстро и почти одинаково — медиана
-- 3,9–4,9 часа у всех одиннадцати компаний (задание 5), так что главная задержка возникает именно
-- на первом контакте. Различия между работодателями заметнее, чем между направлениями.Даже внутри
-- аналитики данных доля обработанных откликов колеблется от 36% до 89,5%, и высокая обработка
-- не гарантирует высокой конверсии, как видно на примере Мосмаркета с 36% обработки и 24% приглашений.
-- Сравнение в задании 7 показало, что ни скорость первого контакта, ни интенсивность переписки
-- с приглашением не связаны — конверсия держится на уровне 13,6–15,4% при любой скорости.
-- Единственный сигнал, более высокая конверсия при успешном звонке (15,8% против 11,1%), получен
-- на слишком маленькой выборке и к тому же может отражать обратную зависимость, ведь звонок с тегом
-- interview может являться скорее следствием решения пригласить. Главное ограничение анализа в том,
-- что статус отклика плохо согласуется с наблюдаемой коммуникацией; у 21% приглашённых в базе нет
-- ни одного контакта, а по 239 событиям работодателя отклик всё ещё числится непросмотренным.
-- Следующим шагом я бы запросила историю смены статусов с датами, чтобы понять, что происходит
-- раньше, коммуникация или решение о приглашении, и сколько времени проходит от первого контакта до этого решения.
