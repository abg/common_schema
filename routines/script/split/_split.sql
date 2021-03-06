-- 
-- 
-- 

DELIMITER $$

DROP PROCEDURE IF EXISTS _split $$
CREATE PROCEDURE _split(
  split_table_schema varchar(128), 
  split_table_name varchar(128),
  split_options varchar(2048) charset utf8,
  split_injected_action_statement TEXT CHARSET utf8, 
  split_injected_text TEXT CHARSET utf8,
  in   id_from      int unsigned,
  in   id_to      int unsigned,
  in   expect_single tinyint unsigned,
  out  consumed_to_id int unsigned,
  in depth int unsigned,
  in should_execute_statement tinyint unsigned
  ) 
MODIFIES SQL DATA
SQL SECURITY INVOKER
COMMENT 'split values by columns...'

main_body: begin
  declare is_overflow tinyint unsigned;
  declare is_range_identical tinyint unsigned;
  declare is_empty_range tinyint unsigned;
  declare deadlock_detected tinyint unsigned;
  declare split_range_size int unsigned;
  declare comparison_clause text charset utf8;
  declare action_statement text charset utf8;
  declare continue handler for 1205 SET deadlock_detected = TRUE;

  set @_split_is_first_step_flag := true;
  
  call _split_deduce_columns(split_table_schema, split_table_name, get_option(split_options, 'index'));
  call _split_init_variables();
  call _split_assign_min_max_variables(id_from, split_table_schema, split_table_name, split_options, is_empty_range);
  
  if is_empty_range then
    leave main_body;
  end if;
  
  call _split_assign_initial_range_start_variables();
  
  set @_query_script_split_step_index := 0;
  set @_query_script_split_total_rowcount := 0;
  set @query_script_split_start_time := SYSDATE();
  
  call _declare_local_variable(id_from, id_from, id_to, depth, '$split_columns', '@query_script_split_columns', FALSE);
  call _declare_local_variable(id_from, id_from, id_to, depth, '$split_index', '@query_script_split_index_name', FALSE);
  call _declare_local_variable(id_from, id_from, id_to, depth, '$split_min', '@query_script_split_min', FALSE);
  call _declare_local_variable(id_from, id_from, id_to, depth, '$split_max', '@query_script_split_max', FALSE);
  call _declare_local_variable(id_from, id_from, id_to, depth, '$split_clause', '@query_script_split_comparison_clause', FALSE);
  call _declare_local_variable(id_from, id_from, id_to, depth, '$split_step', '@query_script_split_step_index', FALSE);
  call _declare_local_variable(id_from, id_from, id_to, depth, '$split_range_start', '@query_script_split_range_start_snapshot', FALSE);
  call _declare_local_variable(id_from, id_from, id_to, depth, '$split_range_end', '@query_script_split_range_end_snapshot', FALSE);
  call _declare_local_variable(id_from, id_from, id_to, depth, '$split_rowcount', '@query_script_split_rowcount', FALSE);
  call _declare_local_variable(id_from, id_from, id_to, depth, '$split_total_rowcount', '@query_script_split_total_rowcount', FALSE);
  call _declare_local_variable(id_from, id_from, id_to, depth, '$split_total_elapsed_time', '@query_script_split_total_elapsed_time', FALSE);
  call _declare_local_variable(id_from, id_from, id_to, depth, '$split_table_schema', '@query_script_split_table_schema', FALSE);
  call _declare_local_variable(id_from, id_from, id_to, depth, '$split_table_name', '@query_script_split_table_name', FALSE);
  
  set split_range_size := least(50000, greatest(100, floor(ifnull(get_option(split_options, 'size'), 1000))));
  _split_step_loop: loop
    call _split_is_range_start_overflow(is_overflow);
    if is_overflow and not @_split_is_first_step_flag then
      leave _split_step_loop;
    end if;
    call _split_assign_range_end_variables(split_table_schema, split_table_name, split_range_size);
    -- We now have a range start+end
    call _split_is_range_start_end_identical(is_range_identical);
    if is_range_identical and not @_split_is_first_step_flag then
      leave _split_step_loop;
    end if;
    -- start split step operation
    call _split_get_step_comparison_clause(comparison_clause);

    set action_statement := REPLACE(split_injected_action_statement, split_injected_text, comparison_clause);

    repeat
      set deadlock_detected := false;
      call exec_single(action_statement);
      if deadlock_detected then
        select 'deadlock detected...' as msg;
      end if;

      set @_query_script_split_step_index := @_query_script_split_step_index + 1;
      set @query_script_split_step_index := @_query_script_split_step_index;
      set @query_script_split_rowcount := @common_schema_rowcount;
      set @_query_script_split_total_rowcount := @_query_script_split_total_rowcount + GREATEST(@query_script_split_rowcount, 0);
      set @query_script_split_total_rowcount := @_query_script_split_total_rowcount;
      set @query_script_split_total_elapsed_time := TIMESTAMPDIFF(MICROSECOND, @query_script_split_start_time, SYSDATE())/1000000.0;
      set @query_script_split_table_schema := split_table_schema;
      set @query_script_split_table_name := split_table_name;
      set @query_script_split_min := @_query_script_split_min;
      set @query_script_split_max := @_query_script_split_max;
      set @query_script_split_columns := @_query_script_split_columns;
      set @query_script_split_index_name := @_query_script_split_index_name;
      call _split_set_step_clause_and_ranges_local_variables(comparison_clause);
    
      call _consume_statement(id_from, id_to, expect_single, consumed_to_id, depth, true, should_execute_statement);

      if @_common_schema_script_break_type IS NOT NULL then
        if @_common_schema_script_break_type = 'break' then
          set @_common_schema_script_break_type := NULL;
        end if;
        leave _split_step_loop;
      end if;
    until deadlock_detected = false
    end repeat;

    call _split_assign_next_range_start_variables();
    set @_split_is_first_step_flag := false;
  end loop;
end $$

DELIMITER ;
