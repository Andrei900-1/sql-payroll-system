CALL sp_calculate_salary(5, 2025);

CREATE OR REPLACE PROCEDURE sp_calculate_salary (
    p_month INT,  -- Месяц (1-12)
    p_year INT    -- Год (например, 2025)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_shift_count INT;  -- Количество рабочих дней в месяце
BEGIN
    -- 1. Подсчет рабочих дней в месяце
    SELECT COUNT(*) INTO v_shift_count
    FROM t_date_work
    WHERE date_part('month', date_x) = p_month
      AND date_part('year', date_x) = p_year;

    -- 2. Создание временной таблицы для расчетов по всем цехам
    DROP TABLE IF EXISTS t_temp_salary_detail;
    CREATE TEMP TABLE t_temp_salary_detail AS
    SELECT 
        p.id AS id_people,
        p.fam,
        p.passport,
        po.post,
        po.post_salary,
        pl.k_place,
        st.id AS status_id,
        st.k_status,
        w.value_x,
        w.defect_x,
        w.price_x,
        d.date_x
    FROM t_people p
    JOIN t_ppp pp ON p.id = pp.id_people
    JOIN t_post po ON pp.id_post = po.id
    JOIN t_place pl ON pp.id_place = pl.id
    JOIN t_work w ON p.id = w.id_people
    JOIN t_status st ON w.id_status = st.id
    JOIN t_date_work d ON w.id_date = d.id
    WHERE 
        pp.date_decree = (
            SELECT MAX(px.date_decree)
            FROM t_ppp px
            WHERE px.id_people = p.id AND px.date_decree <= d.date_x
        )
        AND date_part('month', d.date_x) = p_month
        AND date_part('year', d.date_x) = p_year;

    -- 3. Агрегация данных по сотрудникам
    DROP TABLE IF EXISTS t_temp_salary;
    CREATE TEMP TABLE t_temp_salary AS
    SELECT 
        id_people,
        fam,
        passport,
        -- Берем последний оклад
        (SELECT post_salary FROM t_temp_salary_detail d 
         WHERE d.id_people = t.id_people 
         ORDER BY date_x DESC LIMIT 1) AS post_salary,
        -- Берем последний коэффициент цеха
        (SELECT k_place FROM t_temp_salary_detail d 
         WHERE d.id_people = t.id_people 
         ORDER BY date_x DESC LIMIT 1) AS k_place,
        -- Суммируем дни по всем цехам
        SUM(CASE WHEN status_id = 2 THEN 1 ELSE 0 END) AS day_bus_trip,
        SUM(CASE WHEN status_id = 3 THEN 1 ELSE 0 END) AS day_disease,
        SUM(CASE WHEN status_id = 4 THEN 1 ELSE 0 END) AS day_vacation,
        COUNT(status_id) AS day_all,
        -- Расчет зарплаты по компонентам
        ROUND(SUM(
            CASE 
                WHEN status_id = 2 THEN (post_salary * k_status * k_place) / v_shift_count
                ELSE 0
            END
        ), 2) AS salary_bt,
        ROUND(SUM(
            CASE 
                WHEN status_id = 3 THEN (post_salary * k_status * k_place) / v_shift_count
                ELSE 0
            END
        ), 2) AS salary_d,
        ROUND(SUM(
            CASE 
                WHEN status_id = 4 THEN (post_salary * k_status * k_place) / v_shift_count
                ELSE 0
            END
        ), 2) AS salary_v,
        -- Общая зарплата
        ROUND(SUM(
            CASE 
                WHEN post = 'рабочий' AND status_id > 1 THEN 
                    (post_salary * k_status * k_place) / v_shift_count
                WHEN post = 'рабочий' AND status_id = 1 THEN 
                    (value_x - defect_x) * price_x
                WHEN post IN ('начальник','заместитель','бригадир') THEN 
                    (post_salary * k_status * k_place) / v_shift_count
                ELSE 0
            END
        ), 2) AS salary_all
    FROM t_temp_salary_detail t
    GROUP BY id_people, fam, passport;

    -- 4. Сохранение результатов в основную таблицу
    IF NOT EXISTS (SELECT * FROM information_schema.tables WHERE table_name = 't_salary') THEN
        CREATE TABLE t_salary (
            fam character varying(20),
            passport character varying(10),
            month_x double precision,
            year_x double precision,
            day_bus_trip bigint,
            day_disease bigint,
            day_vacation bigint,
            day_all bigint,
            salary_bt numeric,
            salary_d numeric,
            salary_v numeric,
            salary_all numeric
        );
    END IF;-- Удаляем старые данные за этот месяц
    DELETE FROM t_salary 
    WHERE month_x = p_month AND year_x = p_year;

    -- Вставляем новые данные
    INSERT INTO t_salary (
        fam, passport, month_x, year_x, 
        day_bus_trip, day_disease, day_vacation, day_all,
        salary_bt, salary_d, salary_v, salary_all
    )
    SELECT 
        fam, passport, p_month::double precision, p_year::double precision,
        day_bus_trip, day_disease, day_vacation, day_all,
        salary_bt, salary_d, salary_v, salary_all
    FROM t_temp_salary;

    RAISE NOTICE 'Зарплата за %-% успешно рассчитана', p_month, p_year;
END;
$$;