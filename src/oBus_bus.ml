(*
 * oBus_bus.ml
 * -----------
 * Copyright : (c) 2008, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of obus, an ocaml implementation of D-Bus.
 *)

let section = Lwt_log.Section.make "obus(bus)"

open Lwt
open OBus_private_connection
open OBus_pervasives

type t = OBus_connection.t

module Proxy = OBus_proxy.Make
  (struct
     type proxy = OBus_connection.t
     let cast bus = { OBus_proxy.peer = { OBus_peer.connection = bus;
                                          OBus_peer.name = Some "org.freedesktop.DBus" };
                      OBus_proxy.path = ["org"; "freedesktop"; "DBus"] }
     let make = OBus_proxy.connection
   end)

let op_interface = Proxy.make_interface "org.freedesktop.DBus"

OP_method Hello : string

let error_handler = function
  | OBus_wire.Protocol_error msg ->
      ignore (Lwt_log.error_f ~section "the D-Bus connection with the message bus has been closed due to a protocol error: %s" msg);
      exit 1
  | OBus_connection.Connection_lost ->
      ignore (Lwt_log.info ~section "disconnected from D-Bus message bus");
      exit 0
  | OBus_connection.Transport_error exn ->
      ignore (Lwt_log.error_f ~section "the D-Bus connection with the message bus has been closed due to a transport error: %s" (Printexc.to_string exn));
      exit 1
  | exn ->
      ignore (Lwt_log.error ~section ~exn "the D-Bus connection with the message bus has been closed due to this uncaught exception");
      exit 1

let register_connection ?(set_on_disconnect=true) connection =
  let running = running_of_connection connection in
  match running.running_name with
    | Some _ ->
        (* Do not call two times the Hello method *)
        return ()

    | None ->
        if set_on_disconnect then running.running_on_disconnect := error_handler;
        lwt name = hello connection in
        running.running_name <- Some name;
        return ()

let of_addresses addresses =
  lwt bus = OBus_connection.of_addresses addresses ~shared:true in
  lwt () = register_connection bus in
  return bus

let session_bus = lazy(
  try_lwt
    Lazy.force OBus_address.session >>= of_addresses
  with exn ->
    lwt () = Lwt_log.warning ~exn ~section "Failed to open a connection to the session bus" in
    fail exn
)

let session () = Lazy.force session_bus

let system_bus_state = ref None
let system_bus_mutex = Lwt_mutex.create ()

let system () =
  Lwt_mutex.with_lock system_bus_mutex
    (fun () ->
       match !system_bus_state with
         | Some bus when React.S.value (OBus_connection.running bus) ->
             return bus
         | _ ->
             try_lwt
               lwt bus = Lazy.force OBus_address.system >>= of_addresses in
               system_bus_state := Some bus;
               return bus
             with exn ->
               lwt () = Lwt_log.warning ~exn ~section "Failed to open a connection to the system bus" in
               fail exn)

let prefix = OBus_proxy.Interface.name op_interface ^ ".Error."

exception Access_denied of string
 with obus(prefix ^ "AccessDenied")

exception Service_unknown of string
 with obus(prefix ^ "ServiceUnknown")

exception OBus_match_not_found of string
 with obus(prefix ^ "MatchRuleNotFound")

exception Match_rule_invalid of string
 with obus(prefix ^ "MatchRuleInvalid")

exception Service_unknown of string
 with obus(prefix ^ "ServiceUnknown")

exception Name_has_no_owner of string
 with obus(prefix ^ "NameHasNoOwner")

exception Adt_audit_data_unknown of string
 with obus(prefix ^ "AdtAuditDataUnknown")

exception Selinux_security_context_unknown of string
 with obus(prefix ^ "SELinuxSecurityContextUnknown")

let acquired_names bus = match bus#get with
  | Crashed exn -> raise exn
  | Running running -> running.running_acquired_names

type request_name_result =
    [ `Primary_owner
    | `In_queue
    | `Exists
    | `Already_owner ]

let obus_request_name_result = OBus_type.map obus_uint
  (function
     | 1 -> `Primary_owner
     | 2 -> `In_queue
     | 3 -> `Exists
     | 4 -> `Already_owner
     | n ->
         Printf.ksprintf
           (OBus_type.cast_failure "OBus_bus.obus_request_name_result")
           "invalid result for RequestName: %d" n)
  (function
     | `Primary_owner -> 1
     | `In_queue -> 2
     | `Exists -> 3
     | `Already_owner -> 4)

OP_method RequestName : string -> uint -> request_name_result
let request_name bus ?(allow_replacement=false) ?(replace_existing=false) ?(do_not_queue=false) name =
  request_name bus name ((if allow_replacement then 1 else 0) lor
                           (if replace_existing then 2 else 0) lor
                           (if do_not_queue then 4 else 0))

type release_name_result = [ `Released | `Non_existent | `Not_owner ]

let obus_release_name_result = OBus_type.map obus_uint
  (function
     | 1 -> `Released
     | 2 -> `Non_existent
     | 3 -> `Not_owner
     | n ->
         Printf.ksprintf
           (OBus_type.cast_failure "OBUs_bus.obus_release_name_result")
           "invalid result for ReleaseName: %d" n)
  (function
     | `Released -> 1
     | `Non_existent -> 2
     | `Not_owner -> 3)

OP_method ReleaseName : string -> release_name_result

type start_service_by_name_result = [ `Success | `Already_running ]

let obus_start_service_by_name_result = OBus_type.map obus_uint
  (function
     | 1 -> `Success
     | 2 -> `Already_running
     | n ->
         Printf.ksprintf
           (OBus_type.cast_failure "OBus_bus.obus_start_service_by_name_result")
           "invalid result for StartServiceByName: %d" n)
  (function
     | `Success -> 1
     | `Already_running -> 2)

OP_method StartServiceByName : string -> uint -> start_service_by_name_result
let start_service_by_name bus name = start_service_by_name bus name 0
OP_method NameHasOwner : string -> bool
OP_method ListNames : string list
OP_method ListActivatableNames : string list
OP_method GetNameOwner : string -> string
OP_method ListQueuedOwners : string -> string list

OP_method AddMatch : OBus_match.rule -> unit
OP_method RemoveMatch : OBus_match.rule -> unit

OP_method UpdateActivationEnvironment : (string, string) dict -> unit
OP_method GetConnectionUnixUser : string -> uint
OP_method GetConnectionUnixProcessID : string -> uint
OP_method GetAdtAuditSessionData : string -> byte_array
OP_method GetConnectionSELinuxSecurityContext : string -> byte_array
OP_method ReloadConfig : unit
OP_method GetId : uuid

let obus_name_opt = OBus_type.map obus_string
  (function
     | "" -> None
     | str -> Some str)
  (function
     | None -> ""
     | Some str -> str)

OP_signal NameOwnerChanged : string * name_opt * name_opt
OP_signal NameLost : string
OP_signal NameAcquired : string

let get_peer bus name =
  try_lwt
    lwt unique_name = get_name_owner bus name in
    return (OBus_peer.make bus unique_name)
  with Name_has_no_owner _ ->
    lwt _ = start_service_by_name bus name in
    lwt unique_name = get_name_owner bus name in
    return (OBus_peer.make bus unique_name)

let get_proxy bus name path =
  lwt peer = get_peer bus name in
  return (OBus_proxy.make peer path)
