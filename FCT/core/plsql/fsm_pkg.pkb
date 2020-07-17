create or replace package body &TOOLKIT._pkg 
as

  C_PKG constant varchar2(30 byte) := $$PLSQL_UNIT;
  
  g_log_level number;
  g_user varchar2(30 byte);
  
  /* PL/SQL table to cache notification messages */
  type &TOOLKIT._message_tab is table of varchar2(200 char)
    index by &TOOLKIT._status.fst_id%type;
  
  -- Instances
  g_event_messages &TOOLKIT._message_tab;
  g_event_names &TOOLKIT._message_tab;
  g_status_messages &TOOLKIT._message_tab;
  g_status_names &TOOLKIT._message_tab;
  
  /* Initialize package */
  procedure initialize
  as
    cursor status_message_cur is
      select fst_id, fst_msg_id, fst_name
        from &TOOLKIT._status;
    cursor event_message_cur is
      select fev_id, fev_msg_id, fev_name
        from &TOOLKIT._event;
  begin
    pit.enter_detailed('initialize', C_PKG);
    
    -- cache list of often used messages for statusses
    for fst in status_message_cur loop
      g_status_messages(fst.fst_id) := fst.fst_msg_id;
      g_status_names(fst.fst_id) := fst.fst_name;
    end loop;
    -- ... and events
    for fev in event_message_cur loop
      g_event_messages(fev.fev_id) := fev.fev_msg_id;
      g_event_names(fev.fev_id) := fev.fev_name;
    end loop;
    
    g_log_level := param.get_integer('PIT_&TOOLKIT._DEFAULT_LOG_LEVEL', 'PIT');
    g_user := user;
    
    pit.leave_detailed;
  end initialize;
  
  /* HELPER */
  /* Methode persists retry of a &TOOLKIT. instance to achieve a new status 
   * %param p_&TOOLKIT. &TOOLKIT. instance
   * %param p_retry_schedule schedule to be used for the next retry
   * %usage Is called when a &TOOLKIT. instance could not achieve a new status
   *        and retries it. This method stores the retry event
   */
  procedure persist_retry(
    p_&TOOLKIT. in out nocopy &TOOLKIT._type,
    p_retry_schedule in &TOOLKIT._object.&TOOLKIT._retry_schedule%type)
  as
  begin
    pit.enter_detailed('persist_retry', C_PKG);
    
    update &TOOLKIT._object
       set &TOOLKIT._validity = p_&TOOLKIT..&TOOLKIT._validity,
           &TOOLKIT._retry_schedule = p_retry_schedule
     where &TOOLKIT._id = p_&TOOLKIT..&TOOLKIT._id;
    commit;
    
    pit.leave_detailed;
  end persist_retry;
  
  
  /* Methode delivers the actual session id as offerd in V$SESSION
   */
  function get_session_id
    return varchar2
  as
    l_session_id util_&TOOLKIT..ora_name_type;
  begin
    pit.enter_detailed('get_session_id', C_PKG);
    
    select to_char(sid || ',' || serial#)
      into l_session_id
      from v$session
     where rownum = 1;
     
    pit.leave_detailed;
    return l_session_id;
  end get_session_id;
  
  
  /* Prozedur fordert einen erneuten Ausfuehrungsversuch an
   * %param p_&TOOLKIT. &TOOLKIT.-Instanz
   * %param p_fev_id Ereignis, das erneut ausgeloest werden soll
   * %param p_wait_time Wartezeit, nach der erneut ausgeloest werden soll
   * %param p_try_count Zaehler, der die Anzahl der Versuche aufzeichnet
   * %usage Wird aufgerufen, um ein Ereignis erneut auszuloesen.
   */
  procedure re_fire_event(
    p_&TOOLKIT. in out nocopy &TOOLKIT._type,
    p_fev_id in &TOOLKIT._event.fev_id%type,
    p_wait_time in &TOOLKIT._status.fst_retry_time%type,
    p_try_count in &TOOLKIT._status.fst_retries_on_error%type)
  as
    l_result binary_integer;
    l_try_count binary_integer;
  begin
    pit.enter_optional('re_fire_event', C_PKG);
    if p_wait_time is not null then
      pit.info(
        msg.&TOOLKIT._RETRYING, 
        msg_args(
          p_fev_id, 
          p_&TOOLKIT..&TOOLKIT._fst_id, 
          p_&TOOLKIT..&TOOLKIT._fev_list, 
          to_char(p_try_count)), 
          p_&TOOLKIT..&TOOLKIT._id);
      -- Wait and retry status change
      dbms_lock.sleep(p_wait_time);
      l_result := p_&TOOLKIT..raise_event(p_fev_id);
    end if;
    pit.leave_optional;
  end re_fire_event;
  
  
  /* Prozedur stoppt die erneute Ausloesung eines Ereignisses und setzt die Instanz
   * in den Fehlestatus
   * %param p_&TOOLKIT. &TOOLKIT.-Instanz
   * %usage Sind keine erneuten Ausloesungen des Ereignisses erlaubt oder die maximale
   *        Wiederholungszahl erreicht, wird ein Fehlerereignis ausgeloest und die
   *        Verarbeitung gestoppt
   */
  procedure proceed_with_error_event(
    p_&TOOLKIT. in out nocopy &TOOLKIT._type)
  as
    l_result binary_integer;
    l_event &TOOLKIT._event.fev_id%type;
  begin
    pit.enter_optional('proceed_with_error_event', C_PKG);
    pit.verbose(
      msg.&TOOLKIT._VALIDITY, 
      msg_args(
        to_char(p_&TOOLKIT..&TOOLKIT._validity)),
        p_&TOOLKIT..&TOOLKIT._id);
    select ftr_fev_id
      into l_event
      from &TOOLKIT._transition
     where ftr_fst_id = p_&TOOLKIT..&TOOLKIT._fst_id
       and ftr_fcl_id = p_&TOOLKIT..&TOOLKIT._fcl_id
       and ftr_raise_on_status = util_&TOOLKIT..C_ERROR;
    pit.verbose(msg.&TOOLKIT._THROW_ERROR_EVENT, msg_args(l_event), p_&TOOLKIT..&TOOLKIT._id);
    
    p_&TOOLKIT..&TOOLKIT._fev_list := l_event;
    p_&TOOLKIT..&TOOLKIT._validity := util_&TOOLKIT..C_ERROR;
    
    persist_retry(p_&TOOLKIT., null);
    
    l_result := p_&TOOLKIT..raise_event(l_event);
    pit.leave_optional;
  exception
    when no_data_found then
      -- Werfe generischen Fehler
      l_result := p_&TOOLKIT..raise_event(&TOOLKIT._fev.&TOOLKIT._ERROR);
  end proceed_with_error_event;
  
  
  /* Prozdur zur Pflege von &TOOLKIT._LOG
   * %param p_&TOOLKIT. &TOOLKIT.-Instanz
   * %param p_fev_id Ereignis, das ausgeloest wurde (optional)
   * %param p_fst_id Neuer Status, der eingenommen wurde (optional)
   * %param p_msg ID einer Nachricht aus PIT
   * %param p_msg_args MSG_ARGS-Instanz mit Nachrichtenparametern
   * %usage Wird aufgerufen, um Statuswechsel, Ereignisse und Notifications von
   *        &TOOLKIT. zu protokollieren
   */
  procedure log_change(
    p_&TOOLKIT. in out nocopy &TOOLKIT._type,
    p_fev_id in &TOOLKIT._event.fev_id%type default null,
    p_fst_id in &TOOLKIT._status.fst_id%type default null,
    p_msg in varchar2 default null,
    p_msg_args in msg_args default null)
  as
    l_message message_type;
    l_message_id &TOOLKIT._event.fev_msg_id%type;
    l_user util_&TOOLKIT..ora_name_type;
    l_session util_&TOOLKIT..ora_name_type;
    l_msg_args msg_args;    
    C_PIT_&TOOLKIT. constant varchar2(10) := 'PIT_&TOOLKIT.';
  begin
    pit.enter_optional('log_change', C_PKG);
    -- prepare Message
    case
    when p_fev_id is not null then
      l_message_id := g_event_messages(p_fev_id);
      l_msg_args := msg_args(g_event_names(p_fev_id));
    when p_fst_id = &TOOLKIT._fst.&TOOLKIT._ERROR then
      l_message_id := msg.&TOOLKIT._DELIVERY_FAILED;
      l_msg_args := msg_args(g_status_names(p_fst_id));
    when p_fst_id is not null then
      l_message_id := g_status_messages(p_fst_id);
      l_msg_args := msg_args(g_status_names(p_fst_id));
    else
      l_message_id := p_msg;
      l_msg_args := p_msg_args;
    end case;
    
    l_message := pit.get_message(
                   p_message_name => l_message_id,
                   p_msg_args => l_msg_args, 
                   p_affected_id => to_char(p_FSM.FSM_id));
                   
    -- TODO: Pruefen, ob Ermittlung des Username/Session durch APEX_ADAPTER buggy ist
    if instr(l_message.session_id, ':') > 0 then
      l_user := substr(l_message.session_id, 1, instr(l_message.session_id, ':') - 1);
      l_session := substr(l_message.session_id, instr(l_message.session_id, ':') + 1);
    else
      l_user := g_user;
      l_session := get_session_id;
    end if;
    
    -- LOG
    insert into &TOOLKIT._log(
      fsl_id, fsl_&TOOLKIT._id, fsl_session_id, fsl_user_name, 
      fsl_log_date, fsl_msg_text, fsl_severity, 
      fsl_fst_id, fsl_fev_list, fsl_fcl_id, 
      fsl_msg_id, fsl_msg_args)
    values(
      &TOOLKIT._log_seq.nextval, to_number(l_message.affected_id), l_session, l_user,
      current_timestamp, l_message.message_text, l_message.severity,
      p_&TOOLKIT..&TOOLKIT._fst_id, p_&TOOLKIT..&TOOLKIT._fev_list, p_&TOOLKIT..&TOOLKIT._fcl_id,
      l_message.message_name, pit_pkg.cast_to_msg_args_char(l_message.message_args));
    pit.leave_optional;
  end log_change;
  
  
  /* INTERFACE */
  procedure persist(
    p_&TOOLKIT. in &TOOLKIT._type)
  as
  begin
    pit.enter('persist', C_PKG, msg_params(msg_param('id', p_&TOOLKIT..&TOOLKIT._id)));
    merge into &TOOLKIT._object o
    using (select p_&TOOLKIT..&TOOLKIT._id &TOOLKIT._id,
                  p_&TOOLKIT..&TOOLKIT._fcl_id &TOOLKIT._fcl_id,
                  p_&TOOLKIT..&TOOLKIT._fst_id &TOOLKIT._fst_id,
                  coalesce(p_&TOOLKIT..&TOOLKIT._validity, util_&TOOLKIT..C_OK) &TOOLKIT._validity,
                  p_&TOOLKIT..&TOOLKIT._fev_list &TOOLKIT._fev_list
             from dual) v
       on (o.&TOOLKIT._id = v.&TOOLKIT._id)
     when matched then update set
          &TOOLKIT._fst_id = v.&TOOLKIT._fst_id,
          &TOOLKIT._validity = v.&TOOLKIT._validity,
          &TOOLKIT._fev_list = v.&TOOLKIT._fev_list
     when not matched then insert(&TOOLKIT._id, &TOOLKIT._fcl_id, &TOOLKIT._fst_id, &TOOLKIT._validity, &TOOLKIT._fev_list)
          values(v.&TOOLKIT._id, v.&TOOLKIT._fcl_id, v.&TOOLKIT._fst_id, v.&TOOLKIT._validity, v.&TOOLKIT._fev_list);
    pit.leave;
  end persist;
  

  function raise_event(
    p_&TOOLKIT. in out nocopy &TOOLKIT._type,
    p_fev_id in &TOOLKIT._event.fev_id%type)
    return integer
  as
    l_message_id &TOOLKIT._status.fst_msg_id%type;
    l_old_fst_id &TOOLKIT._status.fst_id%type;
    l_new_fst_id &TOOLKIT._status.fst_id%type;
  begin
    pit.enter('raise_event', C_PKG);
    -- LOG verwalten
    log_change(
      p_&TOOLKIT. => p_&TOOLKIT., 
      p_fev_id => p_fev_id);
    p_&TOOLKIT..&TOOLKIT._validity := util_&TOOLKIT..C_OK;
    pit.leave;
    return util_&TOOLKIT..C_OK;
  exception
    when others then
      pit.sql_exception(msg.&TOOLKIT._SQL_ERROR, msg_args(p_&TOOLKIT..&TOOLKIT._fcl_id, to_char(p_&TOOLKIT..&TOOLKIT._id), p_fev_id));
      return util_&TOOLKIT..C_ERROR;
  end raise_event;
    
  
  procedure retry(
    p_&TOOLKIT. in out nocopy &TOOLKIT._type,
    p_fev_id in &TOOLKIT._event.fev_id%type)
  as
    cursor &TOOLKIT._cur (p_&TOOLKIT._id in &TOOLKIT._object.&TOOLKIT._id%type) is
      select &TOOLKIT..&TOOLKIT._validity,
             &TOOLKIT..&TOOLKIT._fev_id,
             fst.fst_id,
             fst.fst_retries_on_error, 
             fst.fst_retry_schedule, 
             fst.fst_retry_time
        from &TOOLKIT._object &TOOLKIT.
        join &TOOLKIT._status fst
          on &TOOLKIT..&TOOLKIT._fst_id = fst.fst_id
         and &TOOLKIT..&TOOLKIT._fcl_id = fst.fst_fcl_id
       where &TOOLKIT..&TOOLKIT._id = p_&TOOLKIT..&TOOLKIT._id
         and &TOOLKIT..&TOOLKIT._validity != 1;
    l_validity &TOOLKIT._object.&TOOLKIT._validity%type;
  begin
    pit.enter('retry', C_PKG);
    for &TOOLKIT. in &TOOLKIT._cur(p_&TOOLKIT..&TOOLKIT._id) loop
      if &TOOLKIT..fst_retries_on_error > util_&TOOLKIT..C_ERROR then
        pit.verbose(msg.&TOOLKIT._RETRY_REQUESTED, msg_args(p_fev_id, &TOOLKIT..fst_id, util_&TOOLKIT..C_TRUE), p_&TOOLKIT..&TOOLKIT._id);
        -- take retry into account
        -- &TOOLKIT._VALIDITY may have one of the following values:
        -- 0 = no retry planned yet (or succesful state conversion, then this method wouldn't have been called)
        -- 1 = Error, proceed with ftr_raise_on_status = 1 event
        -- > 1 = Retry already scheduled, register next try.
        case &TOOLKIT..&TOOLKIT._validity 
        when 0 then
          -- retry not yet scheduled
          p_&TOOLKIT..&TOOLKIT._validity := &TOOLKIT..fst_retries_on_error + 1;
          persist_retry(p_&TOOLKIT., &TOOLKIT..fst_retry_schedule);
          re_fire_event(p_&TOOLKIT., p_fev_id, &TOOLKIT..fst_retry_time, 1);
        when 1 then
          -- STUB, can not possibly happen
          proceed_with_error_event(p_&TOOLKIT.);
        when 2 then
          proceed_with_error_event(p_&TOOLKIT.);
        else
          p_&TOOLKIT..&TOOLKIT._validity := &TOOLKIT..&TOOLKIT._validity - 1;
          if p_&TOOLKIT..&TOOLKIT._validity > 2 then
            p_&TOOLKIT..notify(msg.&TOOLKIT._RETRY_INFO);
          else
            p_&TOOLKIT..notify(msg.&TOOLKIT._RETRY_WARN);
          end if;
          persist_retry(p_&TOOLKIT., &TOOLKIT..fst_retry_schedule);
          l_validity := &TOOLKIT..fst_retries_on_error - &TOOLKIT..&TOOLKIT._validity + 1;
          re_fire_event(p_&TOOLKIT., p_fev_id, &TOOLKIT..fst_retry_time, l_validity);
        end case;
      else
        pit.verbose(msg.&TOOLKIT._RETRY_REQUESTED, msg_args(p_fev_id, &TOOLKIT..fst_id, util_&TOOLKIT..C_FALSE), p_&TOOLKIT..&TOOLKIT._id);
        proceed_with_error_event(p_&TOOLKIT.);
      end if;
      pit.leave;
    end loop;
  end retry;
  
  
  function allows_event(
    p_&TOOLKIT. in out nocopy &TOOLKIT._type,
    p_fev_id &TOOLKIT._event.fev_id%type)
    return boolean
  as
    l_result boolean;
    l_has_role binary_integer;
  begin
    pit.enter_optional('&TOOLKIT._allows_event', C_PKG);
    -- Pruefe, ob Event im aktuellen Status erlaubt ist
    l_result := instr(':' || p_&TOOLKIT..&TOOLKIT._fev_list || ':', ':' || p_fev_id || ':') > util_&TOOLKIT..C_ERROR;
    
    -- Pruefe, ob aktueller Benutzer erforderliche Rollenrechte besitzt
    select case 
           when ftr_required_role is not null then util_&TOOLKIT..C_ERROR -- auth_user.is_authorized(ftr_required_role)
           else util_&TOOLKIT..C_OK end
      into l_has_role
      from &TOOLKIT._transition
     where ftr_fev_id = p_fev_id
       and ftr_fst_id = p_&TOOLKIT..&TOOLKIT._fst_id
       and ftr_fcl_id = p_&TOOLKIT..&TOOLKIT._fcl_id;
    
    pit.leave_optional;
    return l_result and l_has_role > util_&TOOLKIT..C_ERROR;
  exception
    when no_data_found then
      return false;
  end allows_event;
  
  
  function set_status(
    p_&TOOLKIT. in out nocopy &TOOLKIT._type)
    return number
  as
    cursor next_event_cur(p_&TOOLKIT. in &TOOLKIT._type) is
      select listagg(fev_id, ':') within group (order by fev_id) fev_list,
             max(ftr_raise_automatically) event_auto
        from bl_&TOOLKIT._active_status_event
       where fst_id = p_&TOOLKIT..&TOOLKIT._fst_id
         and fcl_id = p_&TOOLKIT..&TOOLKIT._fcl_id
         and ftr_raise_on_status = p_&TOOLKIT..&TOOLKIT._validity;
    l_old_fst_id &TOOLKIT._status.fst_id%type;
    l_result binary_integer := util_&TOOLKIT..C_OK;
  begin
    pit.enter('set_status', C_PKG);
    pit.assert_not_null(p_&TOOLKIT..&TOOLKIT._fst_id);
    p_&TOOLKIT..&TOOLKIT._validity := coalesce(p_&TOOLKIT..&TOOLKIT._validity, util_&TOOLKIT..C_OK);
    
    -- Ermittle nächste mögliche Events
    for evt in next_event_cur(p_&TOOLKIT.) loop
      p_&TOOLKIT..&TOOLKIT._fev_list := evt.fev_list;
      p_&TOOLKIT..&TOOLKIT._auto_raise := evt.event_auto;
    end loop;
    
    persist(p_&TOOLKIT.);
    
    log_change(
      p_&TOOLKIT. => p_&TOOLKIT.,
      p_fst_id => p_&TOOLKIT..&TOOLKIT._fst_id);
    
    notify(p_&TOOLKIT., msg.&TOOLKIT._NEXT_EVENTS, msg_args(p_&TOOLKIT..&TOOLKIT._fev_list, p_&TOOLKIT..&TOOLKIT._auto_raise));
    
    pit.leave;
    return p_&TOOLKIT..&TOOLKIT._validity;
  exception
    when msg.ASSERTION_FAILED_ERR then
      if p_&TOOLKIT..&TOOLKIT._fst_id != &TOOLKIT._fst.&TOOLKIT._ERROR then
        p_&TOOLKIT..&TOOLKIT._fst_id := &TOOLKIT._fst.&TOOLKIT._ERROR;
        return set_status(p_&TOOLKIT.);
      else
        return util_&TOOLKIT..C_ERROR;
      end if;
    when others then
      pit.sql_exception(msg.SQL_ERROR);
      if p_&TOOLKIT..&TOOLKIT._fst_id != &TOOLKIT._fst.&TOOLKIT._ERROR then
        p_&TOOLKIT..&TOOLKIT._fst_id := &TOOLKIT._fst.&TOOLKIT._ERROR;
        return set_status(p_&TOOLKIT.);
      else
        return util_&TOOLKIT..C_ERROR;
      end if;
  end set_status;
  
  
  procedure set_status(
    p_&TOOLKIT. in out nocopy &TOOLKIT._type)
  as
    l_result number;
  begin
    l_result := set_status(p_&TOOLKIT.);
  end set_status;
  
  
  function get_next_status(
    p_&TOOLKIT. in out nocopy &TOOLKIT._type,
    p_fev_id in &TOOLKIT._event.fev_id%type)
    return varchar2
  as
    l_next_fst_list util_&TOOLKIT..max_sql_char;
    C_DELIMITER constant varchar2(1) := ':';
  begin
    select listagg(ftr_fst_list, C_DELIMITER) within group (order by ftr_fst_list)
      into l_next_fst_list
      from &TOOLKIT._transition
     where ftr_fst_id = p_&TOOLKIT..&TOOLKIT._fst_id
       and ftr_fev_id = p_fev_id
       and ftr_fcl_id = p_&TOOLKIT..&TOOLKIT._fcl_id;
    if instr(l_next_fst_list, C_DELIMITER) = 0 then
      notify(p_&TOOLKIT., msg.&TOOLKIT._NEXT_STATUS_RECOGNIZED, msg_args(l_next_fst_list));
      return l_next_fst_list;
    else
      pit.error(msg.&TOOLKIT._NEXT_STATUS_NU, msg_args(p_&TOOLKIT..&TOOLKIT._fst_id), p_&TOOLKIT..&TOOLKIT._id);
      return null;
    end if;
  exception
    when no_data_found then
      pit.error(msg.&TOOLKIT._NEXT_STATUS_NU, msg_args(p_&TOOLKIT..&TOOLKIT._fst_id), p_&TOOLKIT..&TOOLKIT._id);
      return null;
  end get_next_status;    
  
  
  procedure notify(
    p_&TOOLKIT. in out nocopy &TOOLKIT._type,
    p_msg in util_&TOOLKIT..ora_name_type,
    p_msg_args in msg_args)
  as
  begin
    pit.enter('notify', C_PKG);
    log_change(
      p_&TOOLKIT. => p_&TOOLKIT.,
      p_msg => p_msg,
      p_msg_args => p_msg_args);
    pit.leave;
  end notify;
  
  
  function to_string(
    p_&TOOLKIT. in &TOOLKIT._type)
    return varchar2
  as
    l_result varchar2(32767) := 
    q'[Instanz vom Typ &TOOLKIT._TYPE
    &TOOLKIT._ID: #&TOOLKIT._ID#
    &TOOLKIT._fcl_id: #&TOOLKIT._FCL_ID#
    &TOOLKIT._fst_id: #&TOOLKIT._FST_ID#
    &TOOLKIT._VALIDITY: #&TOOLKIT._VALIDITY#
    event_list: #FEV_LIST#
]';
  begin
    utl_text.bulk_replace(l_result, char_table(
      '#&TOOLKIT._ID#', p_&TOOLKIT..&TOOLKIT._id,
      '#&TOOLKIT._FCL_ID#', p_&TOOLKIT..&TOOLKIT._fcl_id,
      '#&TOOLKIT._FST_ID#', p_&TOOLKIT..&TOOLKIT._fst_id,
      '#&TOOLKIT._VALIDITY#', p_&TOOLKIT..&TOOLKIT._validity,
      '#FEV_LIST#', p_&TOOLKIT..&TOOLKIT._fev_list));
    return l_result;
  end to_string;
  
  
  procedure finalize(
    p_&TOOLKIT. &TOOLKIT._type)
  as
  begin
    null;
  end finalize;

begin
  initialize;
end &TOOLKIT._pkg;
/