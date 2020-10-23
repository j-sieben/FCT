begin

  pit_admin.merge_message_group(
    p_pmg_name => 'fsm',
    p_pmg_description => 'Messages for the Finite Chart Toolkit'
  );

  pit_admin.merge_message(
    p_pms_name => 'fsm_COMPLETED',
    p_pms_pmg_name => 'fsm',
    p_pms_text => q'øfsm has succesfully completed.ø',
    p_pms_description => q'^^',
    p_pms_pse_id => 70,
    p_pms_pml_name => 'AMERICAN',
    p_error_number => null
  );
  
  pit_admin.merge_message(
    p_pms_name => 'fsm_REQ_REJECTED',
    p_pms_pmg_name => 'fsm',
    p_pms_text => q'øYour request was rejected.ø',
    p_pms_description => q'^^',
    p_pms_pse_id => 40,
    p_pms_pml_name => 'AMERICAN',
    p_error_number => null
  );
  
  pit_admin.merge_message(
    p_pms_name => 'fsm_REQ_GRANTED',
    p_pms_pmg_name => 'fsm',
    p_pms_text => q'øYour request was granted.ø',
    p_pms_description => q'^^',
    p_pms_pse_id => 50,
    p_pms_pml_name => 'AMERICAN',
    p_error_number => null
  );
  
  pit_admin.merge_message(
    p_pms_name => 'fsm_REQ_PENDING',
    p_pms_pmg_name => 'fsm',
    p_pms_text => q'øYour request is waiting for a decision.ø',
    p_pms_description => q'^^',
    p_pms_pse_id => 50,
    p_pms_pml_name => 'AMERICAN',
    p_error_number => null
  );

  commit;
  pit_admin.create_message_package;
end;
/
