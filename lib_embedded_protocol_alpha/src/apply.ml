(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2017.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

(** Tezos Protocol Implementation - Main Entry Points *)

open Tezos_context

type error += Wrong_voting_period of Voting_period.t * Voting_period.t (* `Temporary *)
type error += Wrong_endorsement_predecessor of Block_hash.t * Block_hash.t (* `Temporary *)
type error += Duplicate_endorsement of int (* `Permanent *)
type error += Bad_contract_parameter of Contract.t * Script.expr option * Script.expr option (* `Permanent *)
type error += Too_many_faucet


let () =
  register_error_kind
    `Temporary
    ~id:"operation.wrong_endorsement_predecessor"
    ~title:"Wrong endorsement predecessor"
    ~description:"Trying to include an endorsement in a block \
                  that is not the successor of the endorsed one"
    ~pp:(fun ppf (e, p) ->
        Format.fprintf ppf "Wrong predecessor %a, expected %a"
          Block_hash.pp p Block_hash.pp e)
    Data_encoding.(obj2
                     (req "expected" Block_hash.encoding)
                     (req "provided" Block_hash.encoding))
    (function Wrong_endorsement_predecessor (e, p) -> Some (e, p) | _ -> None)
    (fun (e, p) -> Wrong_endorsement_predecessor (e, p)) ;
  register_error_kind
    `Temporary
    ~id:"operation.wrong_voting_period"
    ~title:"Wrong voting period"
    ~description:"Trying to onclude a proposal or ballot \
                  meant for another voting period"
    ~pp:(fun ppf (e, p) ->
        Format.fprintf ppf "Wrong voting period %a, current is %a"
          Voting_period.pp p Voting_period.pp e)
    Data_encoding.(obj2
                     (req "current" Voting_period.encoding)
                     (req "provided" Voting_period.encoding))
    (function Wrong_voting_period (e, p) -> Some (e, p) | _ -> None)
    (fun (e, p) -> Wrong_voting_period (e, p));
  register_error_kind
    `Permanent
    ~id:"badContractParameter"
    ~title:"Contract supplied an invalid parameter"
    ~description:"Either no parameter was supplied to a contract, \
                  a parameter was passed to an account, \
                  or a parameter was supplied of the wrong type"
    Data_encoding.(obj3
                     (req "contract" Contract.encoding)
                     (opt "expectedType" Script.expr_encoding)
                     (opt "providedArgument" Script.expr_encoding))
    (function Bad_contract_parameter (c, expected, supplied) ->
       Some (c, expected, supplied) | _ -> None)
    (fun (c, expected, supplied) -> Bad_contract_parameter (c, expected, supplied)) ;
  register_error_kind
    `Permanent
    ~id:"operation.duplicate_endorsement"
    ~title:"Duplicate endorsement"
    ~description:"Two endorsements received for the same slot"
    ~pp:(fun ppf k ->
        Format.fprintf ppf "Duplicate endorsement for slot %d." k)
    Data_encoding.(obj1 (req "slot" uint16))
    (function Duplicate_endorsement k -> Some k | _ -> None)
    (fun k -> Duplicate_endorsement k);
  register_error_kind
    `Temporary
    ~id:"operation.too_many_faucet"
    ~title:"Too many faucet"
    ~description:"Trying to include a faucet operation in a block \
                 \ with more than 5 faucet operations."
    ~pp:(fun ppf () ->
        Format.fprintf ppf "Too many faucet operation.")
    Data_encoding.unit
    (function Too_many_faucet -> Some () | _ -> None)
    (fun () -> Too_many_faucet)


let apply_delegate_operation_content
    ctxt delegate pred_block block_priority = function
  | Endorsement { block ; slot } ->
      fail_unless
        (Block_hash.equal block pred_block)
        (Wrong_endorsement_predecessor (pred_block, block)) >>=? fun () ->
      fail_when
        (endorsement_already_recorded ctxt slot)
        (Duplicate_endorsement (slot)) >>=? fun () ->
      Baking.check_signing_rights ctxt slot delegate >>=? fun () ->
      let ctxt = record_endorsement ctxt slot in
      let ctxt = Fitness.increase ctxt in
      Baking.pay_endorsement_bond ctxt delegate >>=? fun (ctxt, bond) ->
      Baking.endorsement_reward ~block_priority >>=? fun reward ->
      let { cycle = current_cycle } : Level.t = Level.current ctxt in
      Lwt.return Tez.(reward +? bond) >>=? fun full_reward ->
      Reward.record ctxt delegate current_cycle full_reward
  | Proposals { period ; proposals } ->
      let level = Level.current ctxt in
      fail_unless Voting_period.(level.voting_period = period)
        (Wrong_voting_period (level.voting_period, period)) >>=? fun () ->
      Amendment.record_proposals ctxt delegate proposals
  | Ballot { period ; proposal ; ballot } ->
      let level = Level.current ctxt in
      fail_unless Voting_period.(level.voting_period = period)
        (Wrong_voting_period (level.voting_period, period)) >>=? fun () ->
      Amendment.record_ballot ctxt delegate proposal ballot

let apply_manager_operation_content
    ctxt origination_nonce source = function
  | Transaction { amount ; parameters ; destination } -> begin
      Contract.spend ctxt source amount >>=? fun ctxt ->
      Contract.credit ctxt destination amount >>=? fun ctxt ->
      Contract.get_script ctxt destination >>=? function
      | None -> begin
          match parameters with
          | None ->
              return (ctxt, origination_nonce, None)
          | Some arg ->
              match Micheline.root arg with
              | Prim (_, D_Unit, [], _) ->
                  return (ctxt, origination_nonce, None)
              | _ -> fail (Bad_contract_parameter (destination, None, parameters))
        end
      | Some script ->
          let call_contract argument =
            Script_interpreter.execute
              origination_nonce
              source destination ctxt script amount argument
              (Gas.of_int (Constants.max_gas ctxt))
            >>= function
            | Ok (storage_res, _res, _steps, ctxt, origination_nonce) ->
                (* TODO: pay for the steps and the storage diff:
                   update_script_storage checks the storage cost *)
                Contract.update_script_storage_and_fees
                  ctxt destination
                  Script_interpreter.dummy_storage_fee storage_res >>=? fun ctxt ->
                return (ctxt, origination_nonce, None)
            | Error err ->
                return (ctxt, origination_nonce, Some err) in
          Lwt.return (Script_ir_translator.parse_toplevel script.code) >>=? fun (arg_type, _, _, _) ->
          let arg_type = Micheline.strip_locations arg_type in
          match parameters, Micheline.root arg_type with
          | None, Prim (_, T_unit, _, _) ->
              call_contract (Micheline.strip_locations (Prim (0, Script.D_Unit, [], None)))
          | Some parameters, _ -> begin
              Script_ir_translator.typecheck_data ctxt (parameters, arg_type) >>= function
              | Ok () -> call_contract parameters
              | Error errs ->
                  let err = Bad_contract_parameter (destination, Some arg_type, Some parameters) in
                  return (ctxt, origination_nonce, Some ((err :: errs)))
            end
          | None, _ -> fail (Bad_contract_parameter (destination, Some arg_type, None))
    end
  | Origination { manager ; delegate ; script ;
                  spendable ; delegatable ; credit } ->
      begin match script with
        | None -> return None
        | Some script ->
            Script_ir_translator.parse_script ctxt script >>=? fun _ ->
            return (Some (script, (Script_interpreter.dummy_code_fee, Script_interpreter.dummy_storage_fee)))
      end >>=? fun script ->
      Contract.spend ctxt source Constants.origination_burn >>=? fun ctxt ->
      Contract.spend ctxt source credit >>=? fun ctxt ->
      Contract.originate ctxt
        origination_nonce
        ~manager ~delegate ~balance:credit
        ?script
        ~spendable ~delegatable >>=? fun (ctxt, _, origination_nonce) ->
      return (ctxt, origination_nonce, None)
  | Delegation delegate ->
      Contract.set_delegate ctxt source delegate >>=? fun ctxt ->
      return (ctxt, origination_nonce, None)

let apply_sourced_operation
    ctxt baker_contract pred_block block_prio
    operation origination_nonce ops =
  match ops with
  | Manager_operations { source ; public_key ; fee ; counter ; operations = contents } ->
      Contract.must_exist ctxt source >>=? fun () ->
      Contract.update_manager_key ctxt source public_key >>=? fun (ctxt,public_key) ->
      Operation.check_signature public_key operation >>=? fun () ->
      Contract.check_counter_increment ctxt source counter >>=? fun () ->
      Contract.increment_counter ctxt source >>=? fun ctxt ->
      Contract.spend ctxt source fee >>=? fun ctxt ->
      (match baker_contract with
       | None -> return ctxt
       | Some contract ->
           Contract.credit ctxt contract fee) >>=? fun ctxt ->
      fold_left_s (fun (ctxt, origination_nonce, err) content ->
          match err with
          | Some _ -> return (ctxt, origination_nonce, err)
          | None ->
              Contract.must_exist ctxt source >>=? fun () ->
              apply_manager_operation_content
                ctxt origination_nonce source content)
        (ctxt, origination_nonce, None) contents
  | Delegate_operations { source ; operations = contents } ->
      let delegate = Ed25519.Public_key.hash source in
      Delegates_pubkey.reveal ctxt delegate source >>=? fun ctxt ->
      Operation.check_signature source operation >>=? fun () ->
      (* TODO, see how to extract the public key hash after this operation to
         pass it to apply_delegate_operation_content *)
      fold_left_s (fun ctxt content ->
          apply_delegate_operation_content
            ctxt delegate pred_block block_prio content)
        ctxt contents >>=? fun ctxt ->
      return (ctxt, origination_nonce, None)
  | Dictator_operation (Activate hash) ->
      let dictator_pubkey = Constants.dictator_pubkey ctxt in
      Operation.check_signature dictator_pubkey operation >>=? fun () ->
      activate ctxt hash >>= fun ctxt ->
      return (ctxt, origination_nonce, None)
  | Dictator_operation (Activate_testnet hash) ->
      let dictator_pubkey = Constants.dictator_pubkey ctxt in
      Operation.check_signature dictator_pubkey operation >>=? fun () ->
      let expiration = (* in two days maximum... *)
        Time.add (Timestamp.current ctxt) (Int64.mul 48L 3600L) in
      fork_test_network ctxt hash expiration >>= fun ctxt ->
      return (ctxt, origination_nonce, None)

let apply_anonymous_operation ctxt baker_contract origination_nonce kind =
  match kind with
  | Seed_nonce_revelation { level ; nonce } ->
      let level = Level.from_raw ctxt level in
      Nonce.reveal ctxt level nonce
      >>=? fun (ctxt, delegate_to_reward, reward_amount) ->
      Reward.record ctxt
        delegate_to_reward level.cycle reward_amount >>=? fun ctxt ->
      begin
        match baker_contract with
        | None -> return (ctxt, origination_nonce)
        | Some contract ->
            Contract.credit
              ctxt contract Constants.seed_nonce_revelation_tip >>=? fun ctxt ->
            return (ctxt, origination_nonce)
      end
  | Faucet { id = manager } ->
      (* Free tez for all! *)
      begin
        match baker_contract with
        | None -> return None
        | Some contract -> Contract.get_delegate_opt ctxt contract
      end >>=? fun delegate ->
      if Compare.Int.(faucet_count ctxt < 5) then
        let ctxt = incr_faucet_count ctxt in
        Contract.originate ctxt
          origination_nonce
          ~manager ~delegate ~balance:Constants.faucet_credit ?script:None
          ~spendable:true ~delegatable:true >>=? fun (ctxt, _, origination_nonce) ->
        return (ctxt, origination_nonce)
      else
        fail Too_many_faucet

let apply_operation
    ctxt baker_contract pred_block block_prio operation =
  match operation.contents with
  | Anonymous_operations ops ->
      let origination_nonce = Contract.initial_origination_nonce operation.hash in
      fold_left_s
        (fun (ctxt, origination_nonce) ->
           apply_anonymous_operation ctxt baker_contract origination_nonce)
        (ctxt, origination_nonce) ops >>=? fun (ctxt, origination_nonce) ->
      return (ctxt, Contract.originated_contracts origination_nonce, None)
  | Sourced_operations op ->
      let origination_nonce = Contract.initial_origination_nonce operation.hash in
      apply_sourced_operation
        ctxt baker_contract pred_block block_prio
        operation origination_nonce op >>=? fun (ctxt, origination_nonce, err) ->
      return (ctxt, Contract.originated_contracts origination_nonce, err)

let may_start_new_cycle ctxt =
  Baking.dawn_of_a_new_cycle ctxt >>=? function
  | None -> return ctxt
  | Some last_cycle ->
      let new_cycle = Cycle.succ last_cycle in
      Bootstrap.refill ctxt >>=? fun ctxt ->
      Seed.clear_cycle ctxt last_cycle >>=? fun ctxt ->
      Seed.compute_for_cycle ctxt (Cycle.succ new_cycle) >>=? fun ctxt ->
      Roll.clear_cycle ctxt last_cycle >>=? fun ctxt ->
      Roll.freeze_rolls_for_cycle ctxt (Cycle.succ new_cycle) >>=? fun ctxt ->
      let timestamp = Timestamp.current ctxt in
      Lwt.return (Timestamp.(timestamp +? (Constants.time_before_reward ctxt)))
      >>=? fun reward_date ->
      Reward.set_reward_time_for_cycle
        ctxt last_cycle reward_date >>=? fun ctxt ->
      return ctxt

let begin_full_construction ctxt pred_timestamp proto_header =
  Lwt.return
    (Block_header.parse_unsigned_proto_header
       proto_header) >>=? fun proto_header ->
  Baking.check_baking_rights
    ctxt proto_header pred_timestamp >>=? fun baker ->
  Baking.pay_baking_bond ctxt proto_header baker >>=? fun ctxt ->
  let ctxt = Fitness.increase ctxt in
  return (ctxt, proto_header, baker)

let begin_partial_construction ctxt =
  let ctxt = Fitness.increase ctxt in
  return ctxt

let begin_application ctxt block_header pred_timestamp =
  Baking.check_proof_of_work_stamp ctxt block_header >>=? fun () ->
  Baking.check_fitness_gap ctxt block_header >>=? fun () ->
  Baking.check_baking_rights
    ctxt block_header.proto pred_timestamp >>=? fun baker ->
  Baking.check_signature ctxt block_header baker >>=? fun () ->
  Baking.pay_baking_bond ctxt block_header.proto baker >>=? fun ctxt ->
  let ctxt = Fitness.increase ctxt in
  return (ctxt, baker)

let finalize_application ctxt block_proto_header baker =
  (* end of level (from this point nothing should fail) *)
  let priority = block_proto_header.Block_header.priority in
  let reward = Baking.base_baking_reward ctxt ~priority in
  Nonce.record_hash ctxt
    baker reward block_proto_header.seed_nonce_hash >>=? fun ctxt ->
  Reward.pay_due_rewards ctxt >>=? fun ctxt ->
  (* end of cycle *)
  may_start_new_cycle ctxt >>=? fun ctxt ->
  Amendment.may_start_new_voting_cycle ctxt >>=? fun ctxt ->
  return ctxt

let compare_operations op1 op2 =
  match op1.contents, op2.contents with
  | Anonymous_operations _, Anonymous_operations _ -> 0
  | Anonymous_operations _, Sourced_operations _ -> -1
  | Sourced_operations _, Anonymous_operations _ -> 1
  | Sourced_operations op1, Sourced_operations op2 ->
      match op1, op2 with
      | Delegate_operations _, (Manager_operations _ | Dictator_operation _) -> -1
      | Manager_operations _, Dictator_operation _ -> -1
      | Dictator_operation _, Manager_operations _ -> 1
      | (Manager_operations _ | Dictator_operation _), Delegate_operations _ -> 1
      | Delegate_operations _, Delegate_operations _ -> 0
      | Dictator_operation _, Dictator_operation _ -> 0
      | Manager_operations op1, Manager_operations op2 -> begin
          (* Manager operations with smaller counter are pre-validated first. *)
          Int32.compare op1.counter op2.counter
        end
