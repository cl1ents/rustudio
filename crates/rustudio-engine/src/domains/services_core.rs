//! Members only Roblox's CoreScripts call (core_scripts.rs runs them from
//! Studio's data model patch): ScriptContext:AddCoreScriptLocal, the
//! DataModel's fast-flag and engine-feature queries,
//! UserInputService:GetPlatform, GuiService:GetNotificationTypeList, and
//! MessageBusService / LocalStorageService and StarterGui's
//! RegisterSetCore / RegisterGetCore behind SetCore / GetCore
//! (services_core.luau). Each is in
//! the API dump with RobloxScriptSecurity (or LocalUserSecurity: GetFast*,
//! GetEngineFeature); the runtime's security check refuses game scripts
//! before these run.
//!
//! Flag values: rustudio has none of Roblox's served flag settings, so a
//! defined flag keeps the default its CoreScript gives (`DefineFastFlag(name,
//! default)`), and a flag nothing defined reads false / 0 / "" (estimate:
//! the engine's own C++ flags are unknown here). Engine features answer
//! false: they gate engine API newer than what rustudio has, and the
//! CoreScripts take their older path without them (estimate).

use std::collections::HashMap;

use mlua::{Function, Lua, MultiValue, Table, Value};
use rbx_dom_weak::types::Ref;
use rbx_dom_weak::InstanceBuilder;

use crate::runtime::*;

/// Loads services_core.luau (MessageBusService, LocalStorageService) with
/// the services chunk's helpers, plus `new_object(class)`: a parentless
/// engine-made instance (MessageBusService:Subscribe's MessageBusConnection).
pub(super) fn install(lua: &Lua, rs: &Table) -> mlua::Result<()> {
    rs.set(
        "new_object",
        lua.create_function(|lua, class: String| {
            let r = {
                let mut w = world(lua)?;
                let r = w.dm().dom.insert(Ref::none(), InstanceBuilder::new(class.as_str()).with_name(class.as_str()));
                w.orphans.insert(r);
                r
            };
            inst_value(lua, r)
        })?,
    )?;
    let m: Table = lua.load(include_str!("services_core.luau")).set_name("=rustudio.services.core").call(rs.clone())?;
    lua.set_named_registry_value("svc_core_impl", m)
}

/// The fast flags defined in this DataModel (DefineFastFlag / Int / String).
#[derive(Default)]
pub(super) struct FastFlags(HashMap<String, Fast>);

#[derive(Clone)]
enum Fast {
    Flag(bool),
    Int(i64),
    Str(String),
}

fn name_arg(args: &MultiValue, method: &str) -> mlua::Result<String> {
    match arg(args, 1) {
        Value::String(s) => Ok(s.to_str()?.to_string()),
        _ => Err(rt_err(format!("{method}: Argument 1 missing or nil"))),
    }
}

fn one(lua: &Lua, f: Fast) -> mlua::Result<MultiValue> {
    Ok(MultiValue::from_iter([match f {
        Fast::Flag(b) => Value::Boolean(b),
        Fast::Int(i) => Value::Integer(i),
        Fast::Str(s) => Value::String(lua.create_string(s)?),
    }]))
}

/// settings():GetFFlag / GetFVariable for a CoreScript: a flag it defined,
/// else false / "" (estimate, as GetFast*).
pub(super) fn settings_flag(lua: &Lua, method: &str, flag: &str) -> mlua::Result<MultiValue> {
    let defined = super::state(lua)?.fast_flags.0.get(flag).cloned();
    let v = match (method, defined) {
        ("GetFFlag", Some(Fast::Flag(b))) => Fast::Flag(b),
        ("GetFFlag", _) => Fast::Flag(false),
        (_, Some(Fast::Flag(b))) => Fast::Str(b.to_string()),
        (_, Some(Fast::Int(i))) => Fast::Str(i.to_string()),
        (_, Some(Fast::Str(s))) => Fast::Str(s),
        _ => Fast::Str(String::new()),
    };
    one(lua, v)
}

pub(super) fn luau_member(lua: &Lua, owner: &str, name: &str) -> mlua::Result<bool> {
    let m: Table = lua.named_registry_value("svc_core_impl")?;
    m.contains_key(format!("{owner}.{name}"))
}

pub(super) fn call(lua: &Lua, owner: &str, name: &str, args: &MultiValue) -> mlua::Result<MultiValue> {
    match name {
        // services_core.luau: every member it defines.
        _ if luau_member(lua, owner, name)? => {
            let m: Table = lua.named_registry_value("svc_core_impl")?;
            let f: Function = m.get(format!("{owner}.{name}"))?;
            f.call(args.clone())
        }
        "GetMessageId" | "GetProtocolMethodRequestMessageId" | "GetProtocolMethodResponseMessageId" | "Subscribe"
        | "SubscribeToProtocolMethodRequest" | "SubscribeToProtocolMethodResponse" | "Publish" | "GetLast" | "Call"
        | "PublishProtocolMethodRequest" | "PublishProtocolMethodResponse" | "SetRequestHandler" | "MakeRequest"
        | "Disconnect" | "GetItem" | "SetItem" | "Flush" | "WhenLoaded" | "RegisterSetCore" | "RegisterGetCore" | "SetCore"
        | "GetCore" => {
            let m: Table = lua.named_registry_value("svc_core_impl")?;
            let f: Function = m.get(format!("{owner}.{name}"))?;
            f.call(args.clone())
        }
        "AddCoreScriptLocal" => {
            let script = name_arg(args, name)?;
            let parent = opt_inst(&arg(args, 2)).ok_or_else(|| rt_err("AddCoreScriptLocal: Argument 2 missing or nil"))?;
            if start_core_script(lua, &script, parent)?.is_none() {
                return Err(rt_err(format!("AddCoreScriptLocal: no CoreScript named '{script}'")));
            }
            Ok(MultiValue::new())
        }
        "DefineFastFlag" | "DefineFastInt" | "DefineFastString" => {
            let flag = name_arg(args, name)?;
            let default = match (name, arg(args, 2)) {
                ("DefineFastFlag", Value::Boolean(b)) => Fast::Flag(b),
                ("DefineFastInt", Value::Integer(i)) => Fast::Int(i),
                ("DefineFastInt", Value::Number(n)) => Fast::Int(n as i64),
                ("DefineFastString", Value::String(s)) => Fast::Str(s.to_str()?.to_string()),
                _ => return Err(rt_err(format!("{name}: Argument 2 missing or nil"))),
            };
            let v = super::state(lua)?.fast_flags.0.entry(flag).or_insert(default).clone();
            one(lua, v)
        }
        "GetFastFlag" | "GetFastInt" | "GetFastString" => {
            let flag = name_arg(args, name)?;
            let defined = super::state(lua)?.fast_flags.0.get(&flag).cloned();
            let v = match (name, defined) {
                ("GetFastFlag", Some(v @ Fast::Flag(_)))
                | ("GetFastInt", Some(v @ Fast::Int(_)))
                | ("GetFastString", Some(v @ Fast::Str(_))) => v,
                ("GetFastFlag", _) => Fast::Flag(false),
                ("GetFastInt", _) => Fast::Int(0),
                _ => Fast::Str(String::new()),
            };
            one(lua, v)
        }
        // A flag's served version: rustudio serves none.
        "SetFlagVersion" => {
            name_arg(args, name)?;
            Ok(MultiValue::new())
        }
        // No Roblox play session behind a local Play (estimate: empty).
        "GetPlaySessionId" => Ok(MultiValue::from_iter([Value::String(lua.create_string("")?)])),
        // Studio's client answers the platform Studio runs on; rustudio
        // answers Windows off macOS, the platform whose Studio it follows
        // elsewhere (estimate).
        "GetPlatform" => {
            let platform = if cfg!(target_os = "macos") { 1 } else { 0 };
            Ok(MultiValue::from_iter([super::enum_val(lua, "Platform", platform)?]))
        }
        // The app's notification types by name. Only the two Roblox's own
        // test double (Modules/TestHelpers/MockGuiService.lua) lists are known.
        "GetNotificationTypeList" => {
            let t = lua.create_table()?;
            t.set("NATIVE_EXIT", 35)?;
            t.set("RESTART_APP", 41)?;
            Ok(MultiValue::from_iter([Value::Table(t)]))
        }
        // "GetEngineFeature"
        _ => {
            name_arg(args, name)?;
            Ok(MultiValue::from_iter([Value::Boolean(false)]))
        }
    }
}
