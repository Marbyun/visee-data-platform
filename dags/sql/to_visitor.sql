    with 
    raw_data as (
    select 
    client_id 
    , device_id 
    , session_id 
    , zone_id 
    , object_id 
    , gender
    , created_at::TIMESTAMPTZ created_at 
    , updated_at::TIMESTAMPTZ updated_at 
    , cast (confidence as float) as confidence 
    from visitor_raw vr 
   where 
    (created_at::TIMESTAMPTZ >=  %(filter_start)s::timestamptz
    AND 
    created_at::TIMESTAMPTZ <= %(filter_end)s::timestamptz)
    )
    , count_mode as ( --get mode of gender from each object_id
    select 
    client_id 
    , device_id 
    , session_id 
    , zone_id 
    , object_id 
    , gender
    , count(gender) as mode_count
    from raw_data
    group by 
    client_id 
    , device_id 
    , session_id 
    , zone_id 
    , object_id 
    , gender
    )
    , get_best_mode as ( --get the best mode gender from each object_id
    select 
    client_id 
    , device_id 
    , session_id 
    , zone_id 
    , object_id 
    , gender
    , max(mode_count) as best_mode
    from count_mode
    where mode_count > 1
    group by 
    client_id 
    , device_id 
    , session_id 
    , zone_id 
    , object_id 
    , gender
    )
    , elimination1 as ( --elimination 1 to get just 1 best mode gender from each object_id
    select 
    client_id 
    , device_id 
    , session_id 
    , zone_id 
    , object_id 
    , case
        when count(best_mode) = 1 then 'Correct'
        else 'Incorrect'
    end as flag
    from get_best_mode
    group by 
    client_id 
    , device_id 
    , session_id 
    , zone_id 
    , object_id 
    )
    , gender_by_mode as ( -- final gender by mode
    select 
    gbm.client_id 
    , gbm.device_id 
    , gbm.session_id 
    , gbm.zone_id
    , gbm.object_id
    , gbm.gender
    , e1.flag
    , 'Gender by Mode' as get_by
    from elimination1 e1
    join get_best_mode gbm on e1.client_id = gbm.client_id
        and e1.device_id = gbm.device_id
        and e1.session_id = gbm.session_id
        and e1.zone_id = gbm.zone_id
        and e1.object_id = gbm.object_id
    where e1.flag = 'Correct'
    )
    , get_stdv as ( --the object_id that have same value of the best mode will be process here
    select 
    rd.client_id
    , rd.device_id
    , rd.session_id
    , rd.zone_id
    , rd.object_id
    , rd.gender
    , stddev(rd.confidence) as stdv_conf
    from get_best_mode gm 
    join elimination1 e1 on gm.client_id = e1.client_id
        and gm.device_id = e1.device_id
        and gm.session_id = e1.session_id
        and gm.zone_id = e1.zone_id
        and gm.object_id = e1.object_id
    join raw_data rd on gm.client_id = rd.client_id
        and gm.device_id = rd.device_id
        and gm.session_id = rd.session_id
        and gm.zone_id = rd.zone_id
        and gm.object_id = rd.object_id
        and gm.gender = rd.gender
    where e1.flag = 'Incorrect'
    group by 
    rd.client_id
    , rd.device_id
    , rd.session_id
    , rd.zone_id
    , rd.object_id
    , rd.gender
    )
    , final_stdv as (
    select 
    client_id 
    , device_id 
    , session_id 
    , zone_id
    , object_id 
    , min(stdv_conf) as conf_final
    from get_stdv
    group by 
    client_id 
    , device_id 
    , session_id 
    , zone_id
    , object_id 
    )
    , gender_by_stdv as (
    select 
    gs.client_id 
    , gs.device_id 
    , gs.session_id
    , gs.zone_id
    , gs.object_id
    , gs.gender
    --, fst.conf_final
    , 'Correct' as flag
    , 'Gender by STDV' as get_by
    from final_stdv fst
    join get_stdv gs on fst.client_id = gs.client_id
        and fst.device_id = gs.device_id
        and fst.session_id = gs.session_id
        and fst.zone_id = gs.zone_id
        and fst.object_id = gs.object_id
        and fst.conf_final = gs.stdv_conf
    )
    , union_tab as (
    select *
    from gender_by_mode
    union all
    select *
    from gender_by_stdv
    )
    , final_gender as (
    select 
    rd.client_id 
    , rd.device_id 
    , rd.session_id 
    , rd.zone_id
    , rd.object_id
    , rd.gender
    , ut.get_by
    , max(rd.confidence) as confidence 
    from union_tab ut
    join raw_data rd on ut.client_id = rd.client_id
        and ut.device_id = rd.device_id
        and ut.session_id = rd.session_id
        and ut.zone_id = rd.zone_id
        and ut.object_id = rd.object_id
        and ut.gender = rd.gender
    group by 
    rd.client_id 
    , rd.device_id 
    , rd.session_id
    , rd.zone_id
    , rd.object_id
    , rd.gender
    , ut.get_by
    )
    , get_time as ( --update max(created_at) as "out"  
    select 
    rw.client_id 
    , rw.device_id 
    , rw.session_id 
    , rw.zone_id 
    , rw.object_id 
    , min(case when v."in" is not null then v."in" else rw.created_at end) as "in"
    , max(rw.created_at) as "out"
    from raw_data rw 
    left join visitor v on rw.client_id = v.client_id 
    	and rw.device_id = v.device_id 
    	and rw.session_id = v.session_id 
    	and rw.zone_id = v.zone_id 
    	and rw.object_id = v.object_id 
    group by 
    rw.client_id 
    , rw.device_id 
    , rw.session_id 
    , rw.zone_id 
    , rw.object_id 
    )
    , final_query AS (
        SELECT 
            %(filter_start)s::TIMESTAMPTZ as created_at
            , %(filter_end)s::TIMESTAMPTZ as updated_at
            , fg.client_id
            , fg.device_id
            , fg.session_id
            , fg.object_id
            , fg.zone_id
            , date(gt."in") AS "date"
            , gt."in"
            , gt."out"
            , (gt."out" - gt."in") AS duration
            , gender
            , '' as age
            , fg.confidence
        FROM final_gender fg
        join get_time gt on fg.client_id = gt.client_id
            and fg.device_id = gt.device_id
            and fg.session_id = gt.session_id
            and fg.zone_id = gt.zone_id
            and fg.object_id = gt.object_id
    )
    INSERT INTO visitor (created_at, updated_at, client_id, device_id, session_id, object_id, zone_id, "date", "in", "out", duration, gender, age, confidence)
    SELECT
        created_at 
        ,updated_at
        ,client_id
        ,device_id
        ,session_id
        ,object_id
        ,zone_id
        ,"date"
        ,"in"
        ,"out"
        ,duration
        ,gender
        ,age
        ,confidence
    FROM final_query
    ON CONFLICT on constraint visitor_conflict --(client_id, device_id, session_id, object_id, zone_id, "date")
    DO UPDATE SET
        updated_at = EXCLUDED.updated_at
        ,"out" = EXCLUDED."out"
        ,duration = EXCLUDED.duration
        ,gender = EXCLUDED.gender
        ,age = EXCLUDED.age
        ,confidence = EXCLUDED.confidence