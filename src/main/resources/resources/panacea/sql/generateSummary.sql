delete from @results_schema.pnc_study_summary_path where study_id = @studyId and source_id = @sourceId;

insert into @results_schema.pnc_study_summary_path (pnc_stdy_smry_id, study_id, source_id, tx_path_parent_key, tx_stg_cmb, tx_stg_cmb_pth, tx_seq, tx_stg_cnt, tx_stg_avg_dr)
select seq_pnc_stdy_smry.nextval, 18, 2, null, aggregatePath.combo_ids, aggregatePath.combo_seq, aggregatePath.tx_seq, aggregatePath.patientCount, aggregatePath.averageDurationDays 
from
  (select combo_ids combo_ids, combo_seq combo_seq, tx_seq tx_seq, count(*) patientCount, avg(combo_duration) averageDurationDays from #_PNC_TMP_CMB_SQ_CT ptTxPath
    group by combo_ids, combo_seq, tx_seq) aggregatePath;

merge into @results_schema.pnc_study_summary_path  m
using
  (
	select pathsum.rowid as the_rowid, parentpath.pnc_stdy_smry_id as parentKey, updateParentPath.parentPath pPath, 
    parentPath.tx_stg_cnt parentCount, pathSum.tx_stg_cnt childCount, NVL(ROUND(pathSum.tx_stg_cnt/parentPath.tx_stg_cnt * 100,2),0) percentage
    from @results_schema.pnc_study_summary_path pathSum
    join (select rowid, SUBSTR(tx_stg_cmb_pth , 0 , length(tx_stg_cmb_pth) - length(tx_stg_cmb) - 1 ) as parentPath
    from @results_schema.pnc_study_summary_path) updateParentPath
    on updateParentPath.rowid = pathSum.rowid
    join @results_schema.pnc_study_summary_path parentPath
    on updateParentPath.parentPath = parentPath.tx_stg_cmb_pth group by pathsum.rowid, parentpath.pnc_stdy_smry_id, updateParentPath.parentPath, parentPath.tx_stg_cnt, pathSum.tx_stg_cnt
  ) m1
  on
  (
     m.rowid = m1.the_rowid
  )
  WHEN MATCHED then update set m.tx_path_parent_key = m1.parentKey, m.tx_stg_percentage = m1.percentage;

merge into @results_schema.pnc_study_summary_path  m
using
  (
    select pathsum.rowid as the_rowid, rootCount.totalRootCount,
    rootCount.totalRootCount parentCount, pathSum.tx_stg_cnt childCount, NVL(ROUND(pathSum.tx_stg_cnt/rootCount.totalRootCount * 100,2),0) percentage
    from @results_schema.pnc_study_summary_path pathSum, (select sum(tx_stg_cnt) totalRootCount from @results_schema.pnc_study_summary_path
    where tx_path_parent_key is null) rootCount
    where tx_path_parent_key is null
  ) m1
  on
  (
     m.rowid = m1.the_rowid
  )
  WHEN MATCHED then update set m.tx_stg_percentage = m1.percentage;

delete from @results_schema.pnc_study_summary where study_id = @studyId and source_id = @sourceId;
  
insert into @results_schema.pnc_study_summary (study_id, source_id, study_results)
select @studyId, @sourceId, JSON from (
select JSON from (
SELECT
   table_row_id,
   DBMS_XMLGEN.CONVERT (
     EXTRACT(
       xmltype('<?xml version="1.0"?><document>' ||
               XMLAGG(
                 XMLTYPE('<V>' || DBMS_XMLGEN.CONVERT(JSON)|| '</V>')
                 order by rnum).getclobval() || '</document>'),
               '/document/V/text()').getclobval(),1) AS JSON
FROM (select allRoots.rnum rnum, 1 table_row_id,
CASE 
    WHEN rnum = 1 THEN '{"combo_id": "root","children": [' || substr(JSON_SNIPPET, 2, length(JSON_SNIPPET))
    ELSE JSON_SNIPPET
END
as JSON
from 
(WITH connect_by_query as (
  SELECT 
     ROWNUM                               as rnum
    ,tx_stg_cmb                           as combo_id
    ,tx_stg_cmb_pth                       as current_path
    ,tx_seq                               as path_seq
    ,tx_stg_avg_dr                        as avg_duration
    ,tx_stg_cnt                           as pt_count
    ,tx_stg_percentage                    as pt_percentage
    ,concepts.conceptsName                as concept_names
    ,concepts.conceptsArray               as combo_concepts
    ,LEVEL                                as Lvl
  FROM @results_schema.pnc_study_summary_path smry
  join
  (select pnc_stdy_smry_id smry_id, 
    '[' || wm_concat('{"conceptName":' || '"' || concept.concept_name  || '"' || 
    ',"conceptId":' || concept.concept_id || '}') || ']' conceptsArray,
    wm_concat(concept.concept_name) conceptsName
    from @results_schema.pnc_study_summary_path sumPath
    join (select comb.pnc_tx_stg_cmb_id comb_id, combmap.concept_id concept_id, combmap.concept_name concept_name 
    from @results_schema.pnc_tx_stage_combination comb
    join @results_schema.pnc_tx_stage_combination_map combMap 
    on comb.pnc_tx_stg_cmb_id = combmap.pnc_tx_stg_cmb_id
    and comb.study_id = 18) concept
  on concept.comb_id = sumPath.tx_stg_cmb
  group by sumpath.pnc_stdy_smry_id
  ) concepts
  on concepts.smry_id = smry.pnc_stdy_smry_id
  START WITH pnc_stdy_smry_id in (select pnc_stdy_smry_id from @results_schema.pnc_study_summary_path
        where 
        study_id = 18
        and source_id = 2
        and tx_path_parent_key is null)
  CONNECT BY PRIOR pnc_stdy_smry_id = tx_path_parent_key
  ORDER SIBLINGS BY pnc_stdy_smry_id
)
select 
  rnum rnum,
  CASE 
    WHEN Lvl = 1 THEN ',{'
    WHEN Lvl - LAG(Lvl) OVER (order by rnum) = 1 THEN ',"children" : [{' 
    ELSE ',{' 
  END 
  || ' "combo_id" : ' || combo_id || ' '
  || ' ,"concept_names" : "' || concept_names || '" '  
  || ' ,"patient_counts" : ' || pt_count || ' '
  || ' ,"percentage" : "' || pt_percentage || '" '  
  || ' ,"average_duration" : ' || avg_duration || ' '
  || ',"concepts" : ' || combo_concepts 
  || CASE WHEN LEAD(Lvl, 1, 1) OVER (order by rnum) - Lvl <= 0 
     THEN '}' || rpad( ' ', 1+ (-2 * (LEAD(Lvl, 1, 1) OVER (order by rnum) - Lvl)), ']}' )
     ELSE NULL 
  END as JSON_SNIPPET
from connect_by_query
order by rnum) allRoots
union all
select rnum as rnum, table_row_id as table_row_id, to_clob(']}') as JSON from (
	select distinct 1/0F as rnum, 1 as table_row_id from pnc_study_summary_path)
--  select distinct 1000000 as rnum, 1 as table_row_id from pnc_study_summary_path)
--sql render remove "dual", so I have to trick by using a real table(pnc_study_summary_path) select 1000000  as rnum, 1 as table_row_id, to_clob(']}') as JSON from dual
)
GROUP BY
   table_row_id));
