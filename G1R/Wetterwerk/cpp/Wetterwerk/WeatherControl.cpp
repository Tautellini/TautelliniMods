// WeatherControl.cpp  --  weather control + reflection editor (UE4SS C++ API)
//
// API NOTES. All UE4SS symbols used here are confirmed present in this build's
// UE4SS.dll and headers (ForEachPropertyInChain, CastField, FNumericProperty,
// FBoolProperty, FStructProperty, ProcessEvent, GetFunctionByNameInChain). The
// reflection-editor pattern mirrors UE4SS's own Live View (GUI/LiveView.cpp).
//
// pcall has no C++ equivalent: a bad UObject deref crashes hard. The guards here
// (null checks, Default__ filtering, re-finding actors fresh each tick, never
// caching a UE pointer across ticks) are the real safety.

#include "WeatherControl.hpp"

// <Windows.h> defines min/max MACROS that break std::min/std::max inside the UE4SS
// container headers (Array.hpp). Suppress them before Windows.h is pulled in.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <cstdint>
#include <bit>
#include <Windows.h>

#include <DynamicOutput/DynamicOutput.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UClass.hpp>
#include <Unreal/UStruct.hpp>
#include <Unreal/UScriptStruct.hpp>
#include <Unreal/UFunction.hpp>
#include <Unreal/FProperty.hpp>
#include <Unreal/Property/FNumericProperty.hpp>
#include <Unreal/Property/FBoolProperty.hpp>
#include <Unreal/Property/FStructProperty.hpp>
#include <Unreal/Property/FArrayProperty.hpp>
#include <Unreal/Property/FObjectProperty.hpp>
#include <Unreal/Core/Containers/ScriptArray.hpp>

using namespace RC;
using namespace RC::Unreal;

namespace
{
    constexpr const wchar_t* kControllerClass = STR("GothicUltraDynamicControlerAS");
    constexpr const wchar_t* kWeatherClass    = STR("GothicUltraDynamicWeatherAS");
    constexpr const wchar_t* kSkyClass        = STR("GothicUltraDynamicSkyAS");

    // how deep to recurse into structs (actor -> struct -> scalar covers colors and
    // vectors; depth 2 also catches a struct-in-struct). Kept small to bound work.
    constexpr int kMaxDepth = 2;

    std::string narrow(const std::wstring& w)
    {
        if (w.empty()) return {};
        int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(),
                                    nullptr, 0, nullptr, nullptr);
        if (n <= 0) return {};
        std::string s(static_cast<size_t>(n), '\0');
        WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(),
                            s.data(), n, nullptr, nullptr);
        return s;
    }

    std::string join_path(const std::vector<std::string>& path)
    {
        std::string s;
        for (size_t i = 0; i < path.size(); ++i)
        {
            if (i) s += '.';
            s += path[i];
        }
        return s;
    }

    std::string preset_leaf(const std::string& full)
    {
        std::string s = full;
        auto sp = s.find_last_of(' ');
        if (sp != std::string::npos) s = s.substr(sp + 1);
        auto sl = s.find_last_of("/\\");
        if (sl != std::string::npos) s = s.substr(sl + 1);
        auto dot = s.find('.');
        if (dot != std::string::npos) s = s.substr(0, dot);
        if (s.size() >= 2 && s.compare(s.size() - 2, 2, "_C") == 0)
            s = s.substr(0, s.size() - 2);
        return s;
    }

    std::string preset_label(const std::string& full)
    {
        std::string s = preset_leaf(full);
        static const std::string pfx = "Gothic_";
        if (s.size() >= pfx.size() && _strnicmp(s.c_str(), pfx.c_str(), pfx.size()) == 0)
            s = s.substr(pfx.size());
        for (auto& c : s) if (c == '_') c = ' ';
        return s;
    }

    // find a property by name on a UStruct (whole inheritance chain), or nullptr.
    FProperty* find_prop(UStruct* ustruct, const std::string& name)
    {
        if (!ustruct) return nullptr;
        for (FProperty* p : ustruct->ForEachPropertyInChain())
        {
            if (p && narrow(p->GetName()) == name) return p;
        }
        return nullptr;
    }
}

UObject* WeatherControl::find_live(const wchar_t* class_name)
{
    std::vector<UObject*> results;
    UObjectGlobals::FindAllOf(class_name, results);
    for (UObject* o : results)
    {
        if (!o) continue;
        if (o->GetName().find(STR("Default__")) != std::wstring::npos) continue;
        return o;
    }
    return nullptr;
}

UObject* WeatherControl::find_actor(const std::string& section)
{
    if (section == "Weather")    return find_live(kWeatherClass);
    if (section == "Sky")        return find_live(kSkyClass);
    if (section == "Controller") return find_live(kControllerClass);
    return nullptr;
}

bool WeatherControl::call_set_weather(UObject* controller, int index)
{
    if (!controller) return false;
    UFunction* fn = controller->GetFunctionByNameInChain(STR("SetCurrentWeatherImmediate"));
    if (!fn) fn = controller->GetFunctionByNameInChain(STR("SetCurrentWeather"));
    if (!fn) return false;
    struct { int32_t NewWeather; } params{ index };
    controller->ProcessEvent(fn, &params);
    return true;
}

int WeatherControl::call_get_weather(UObject* controller)
{
    if (!controller) return -1;
    UFunction* fn = controller->GetFunctionByNameInChain(STR("GetCurrentWeather"));
    if (!fn) return -1;
    // GetCurrentWeather returns a SINGLE-BYTE enum, not an int32 (proven: after
    // SetCurrentWeather(1), a 4-byte read returned 0xFFFFFF01 = the real 0x01 in the
    // low byte). Read one signed byte: -1 = none, 0..N = the weather index. Reading
    // the low byte is robust whether the return is int8 or int32 for valid indices.
    uint8_t buf[8] = { 0 };
    controller->ProcessEvent(fn, buf);
    return static_cast<int>(static_cast<int8_t>(buf[0]));
}

// #controller.ListContainer.Weathers, or -1 if unreadable. The real preset count
// (the preset grid was guessing 10; out-of-range indices like 8/9 just clamp).
int WeatherControl::read_preset_count(UObject* controller)
{
    if (!controller) return -1;
    UClass* c = controller->GetClassPrivate();
    if (!c) return -1;
    FProperty* lc = find_prop(c, "ListContainer");
    auto* lcsp = lc ? CastField<FStructProperty>(lc) : nullptr;
    if (!lcsp) return -1;
    void* lcptr = lc->ContainerPtrToValuePtr<void>(controller);
    UScriptStruct* ss = lcsp->GetStruct();
    if (!lcptr || !ss) return -1;
    FProperty* wp = find_prop(ss, "Weathers");
    auto* ap = wp ? CastField<FArrayProperty>(wp) : nullptr;
    if (!ap) return -1;
    void* arrptr = wp->ContainerPtrToValuePtr<void>(lcptr);
    if (!arrptr) return -1;
    return std::bit_cast<FScriptArray*>(arrptr)->Num();
}

void WeatherControl::read_preset_name(UObject* weather,
                                      std::string& out_name, std::string& out_leaf)
{
    if (!weather) return;
    UObject** asset = weather->GetValuePtrByPropertyNameInChain<UObject*>(STR("Weather"));
    if (!asset || !*asset) return;
    std::string full = narrow((*asset)->GetFullName());
    if (full.empty()) return;
    out_leaf = preset_leaf(full);
    out_name = preset_label(full);
}

namespace { void dump_props(UObject* obj, const wchar_t* label); } // defined below

// dump the key facts once when the controller is (re)acquired, so we can see from
// the UE4SS.log whether the function calls and the preset read actually work
// (these are AngelScript-class methods; ProcessEvent may behave differently than
// the Lua call path, so we measure instead of assume).
void WeatherControl::log_diagnostics(UObject* controller, UObject* weather)
{
    auto has = [&](const wchar_t* n) {
        return controller->GetFunctionByNameInChain(n) ? STR("found") : STR("MISSING");
    };
    Output::send<LogLevel::Verbose>(STR("[Wetterwerk] DIAG controller={}\n"),
        controller->GetFullName());
    Output::send<LogLevel::Verbose>(STR("[Wetterwerk] DIAG fns: GetCurrentWeather={}, ")
        STR("SetCurrentWeatherImmediate={}, SetCurrentWeather={}\n"),
        has(STR("GetCurrentWeather")), has(STR("SetCurrentWeatherImmediate")),
        has(STR("SetCurrentWeather")));
    Output::send<LogLevel::Verbose>(STR("[Wetterwerk] DIAG GetCurrentWeather()={}, ")
        STR("ListContainer.Weathers count={}\n"),
        call_get_weather(controller), read_preset_count(controller));
    if (weather)
    {
        UObject** asset = weather->GetValuePtrByPropertyNameInChain<UObject*>(STR("Weather"));
        Output::send<LogLevel::Verbose>(STR("[Wetterwerk] DIAG weatherActor={}, Weather asset={}\n"),
            weather->GetFullName(),
            (asset && *asset) ? (*asset)->GetFullName() : std::wstring(STR("<null>")));
    }
    else
    {
        Output::send<LogLevel::Verbose>(STR("[Wetterwerk] DIAG weatherActor=<not found>\n"));
    }
    // dump the UDS-class property names + types so we can find the real weather-list
    // (ARRAY) and preset-name (OBJECT) properties.
    dump_props(controller, STR("CTRL"));
    dump_props(weather, STR("WEATHER"));
}

void WeatherControl::set_cycle_flags(UObject* controller, UObject* weather, bool randomize_on)
{
    UObject* actors[] = { controller, weather };
    for (UObject* a : actors)
    {
        if (!a) continue;
        UClass* ac = a->GetClassPrivate();
        if (!ac) continue;
        for (const wchar_t* flag : { STR("Randomize Weather"), STR("Enable Logic") })
        {
            if (FProperty* p = find_prop(ac, narrow(flag)))
            {
                if (auto* bp = CastField<FBoolProperty>(p))
                    bp->SetPropertyValueInContainer(a, randomize_on);
            }
        }
    }
}

namespace
{
    // A property's DECLARING class tells us whether it is a UDS weather variable
    // (the BlueprintGenerated "_C" classes, or the Gothic/UltraDynamic AngelScript
    // classes) or inherited engine plumbing (AActor/UObject/components/...). Only
    // the former are worth editing; the latter are shown read-only. This is not a
    // perfect "has a visible effect" oracle (the game's lerp can still pull a real
    // weather value back), but it cleanly removes the engine noise.
    bool is_engine_class(const std::string& name)
    {
        if (name.size() >= 2 && name.compare(name.size() - 2, 2, "_C") == 0) return false;
        for (const char* kw : { "Dynamic", "Ultra", "Gothic", "Weather", "Sky" })
            if (name.find(kw) != std::string::npos) return false;
        return true;
    }

    // emit one property: a scalar becomes a Knob; a struct recurses into its members
    // (color/vector channels). `engine` is inherited from the declaring class and
    // propagates to nested members.
    void emit_property(FProperty* p, void* container, const char* section,
                       const std::vector<std::string>& prefix,
                       std::vector<WeatherControl::Knob>& out, int depth, bool engine)
    {
        if (!p || !container) return;
        std::string name = narrow(p->GetName());
        if (name.empty()) return;
        std::vector<std::string> path = prefix;
        path.push_back(name);

        if (auto* bp = CastField<FBoolProperty>(p))
        {
            WeatherControl::Knob k;
            k.section = section; k.path = path; k.label = join_path(path);
            k.kind = 2; k.flag = bp->GetPropertyValueInContainer(container); k.engine = engine;
            out.push_back(std::move(k));
        }
        else if (auto* np = CastField<FNumericProperty>(p))
        {
            void* vp = p->ContainerPtrToValuePtr<void>(container);
            if (!vp) return;
            WeatherControl::Knob k;
            k.section = section; k.path = path; k.label = join_path(path); k.engine = engine;
            if (np->IsFloatingPoint()) { k.kind = 0; k.num = np->GetFloatingPointPropertyValue(vp); }
            else if (np->IsInteger()) { k.kind = 1; k.num = static_cast<double>(np->GetSignedIntPropertyValue(vp)); }
            else return;
            out.push_back(std::move(k));
        }
        else if (auto* sp = CastField<FStructProperty>(p))
        {
            if (depth < kMaxDepth)
            {
                void* structptr = p->ContainerPtrToValuePtr<void>(container);
                UScriptStruct* ss = sp->GetStruct(); // TObjectPtr -> raw via operator T*()
                if (structptr && ss)
                    for (FProperty* m : ss->ForEachPropertyInChain())
                        emit_property(m, structptr, section, path, out, depth + 1, engine);
            }
        }
        // object/array/name/string/enum/delegate are not scalar values; skipped.
    }

    // enumerate every scalar on an actor, walking the class chain so each property
    // is classified by the class that DECLARES it.
    void enumerate_actor(UObject* actor, const char* section,
                         std::vector<WeatherControl::Knob>& out)
    {
        if (!actor) return;
        UClass* cls = actor->GetClassPrivate();
        for (UStruct* c = cls; c; c = c->GetSuperStruct())
        {
            bool engine = is_engine_class(narrow(c->GetName()));
            for (FProperty* p : c->ForEachProperty())
                emit_property(p, actor, section, {}, out, 0, engine);
        }
    }

    // one-shot log dump of an object's OWN (UDS-class) properties + their coarse
    // type, so we can find the real weather-list (array) and preset-name (object)
    // properties from evidence (the guessed "ListContainer"/"Weather" names failed).
    void dump_props(UObject* obj, const wchar_t* label)
    {
        if (!obj) return;
        UClass* cls = obj->GetClassPrivate();
        int n = 0;
        for (UStruct* c = cls; c; c = c->GetSuperStruct())
        {
            if (is_engine_class(narrow(c->GetName()))) break; // only the UDS classes
            for (FProperty* p : c->ForEachProperty())
            {
                const wchar_t* t = STR("other");
                if (CastField<FBoolProperty>(p)) t = STR("bool");
                else if (CastField<FNumericProperty>(p)) t = STR("num");
                else if (CastField<FArrayProperty>(p)) t = STR("ARRAY");
                else if (CastField<FObjectProperty>(p)) t = STR("OBJECT");
                else if (CastField<FStructProperty>(p)) t = STR("struct");
                Output::send<LogLevel::Verbose>(STR("[Wetterwerk] PROP {} {} : {}\n"),
                    std::wstring(label), p->GetName(), std::wstring(t));
                if (++n > 120) return;
            }
        }
    }
}

void WeatherControl::tick()
{
    UObject* controller = find_live(kControllerClass);
    UObject* weather    = find_live(kWeatherClass);
    UObject* sky        = find_live(kSkyClass);

    Snapshot s;
    { std::lock_guard<std::mutex> lk(m_mutex); s = m_state; } // carry hold/lockedIndex
    const bool wasReady = s.ready;

    if (!controller)
    {
        std::lock_guard<std::mutex> lk(m_mutex);
        m_state.ready = false;
        return;
    }
    s.ready = true;
    const int realCount = read_preset_count(controller);
    s.count = (realCount > 0) ? realCount : m_count_fallback;

    int idx = call_get_weather(controller);
    if (idx >= 0)
    {
        s.index = idx;
        std::string name, leaf;
        read_preset_name(weather, name, leaf);
        if (!name.empty()) s.name = name;
        if (!leaf.empty()) s.leaf = leaf;
    }

    // one-shot diagnostic dump on (re)acquire, so the log shows whether the AS-class
    // function calls and the preset read actually work
    if (!wasReady) log_diagnostics(controller, weather);

    // enumerate every value on the weather actors, each classified by its declaring
    // class (the actor's own UDS variables vs inherited engine plumbing). The UI
    // shows the own variables editable and the engine ones read-only.
    s.knobs.clear();
    enumerate_actor(weather,    "Weather",    s.knobs);
    enumerate_actor(sky,        "Sky",        s.knobs);
    enumerate_actor(controller, "Controller", s.knobs);

    // Hold watchdog: re-assert the pinned preset whenever the game drifted off it
    if (s.hold && s.lockedIndex >= 0 && s.index >= 0 && s.index != s.lockedIndex)
    {
        call_set_weather(controller, s.lockedIndex);
        s.index = s.lockedIndex;
    }

    std::lock_guard<std::mutex> lk(m_mutex);
    m_state = std::move(s);
}

void WeatherControl::apply_writes()
{
    std::vector<Knob> writes;
    { std::lock_guard<std::mutex> lk(m_write_mutex); writes.swap(m_writes); }
    if (writes.empty()) return;

    for (const Knob& w : writes)
    {
        UObject* actor = find_actor(w.section);
        if (!actor || w.path.empty()) continue;

        // walk the struct path (all but the last component) to the container that
        // holds the scalar; re-resolved fresh, so no stale pointers.
        void* container = actor;
        UClass* actorClass = actor->GetClassPrivate();
        if (!actorClass) continue;
        UStruct* ustruct = actorClass;
        bool ok = true;
        for (size_t i = 0; i + 1 < w.path.size(); ++i)
        {
            FProperty* p = find_prop(ustruct, w.path[i]);
            auto* sp = p ? CastField<FStructProperty>(p) : nullptr;
            if (!sp) { ok = false; break; }
            UScriptStruct* ss = sp->GetStruct(); // TObjectPtr -> raw via operator T*()
            container = p->ContainerPtrToValuePtr<void>(container);
            ustruct = ss;
            if (!container || !ustruct) { ok = false; break; }
        }
        if (!ok) continue;

        FProperty* leaf = find_prop(ustruct, w.path.back());
        if (!leaf) continue;

        if (w.kind == 2)
        {
            if (auto* bp = CastField<FBoolProperty>(leaf))
                bp->SetPropertyValueInContainer(container, w.flag);
        }
        else if (auto* np = CastField<FNumericProperty>(leaf))
        {
            void* vp = leaf->ContainerPtrToValuePtr<void>(container);
            if (!vp) continue;
            if (w.kind == 1) np->SetIntPropertyValue(vp, static_cast<int64_t>(w.num));
            else             np->SetFloatingPointPropertyValue(vp, w.num);
        }
    }
}

void WeatherControl::queue_write(const Knob& edit)
{
    std::lock_guard<std::mutex> lk(m_write_mutex);
    m_writes.push_back(edit);
}

void WeatherControl::set_preset(int index)
{
    // out-of-range index CRASHES the game (SetCurrentWeatherImmediate indexes the
    // weather list without bounds-checking). Refuse anything outside the known count.
    int safeCount;
    { std::lock_guard<std::mutex> lk(m_mutex); safeCount = m_state.count; }
    if (safeCount <= 0) safeCount = m_count_fallback;
    if (index < 0 || index >= safeCount)
    {
        Output::send<LogLevel::Verbose>(
            STR("[Wetterwerk] set_preset({}) REFUSED (out of range 0..{})\n"),
            index, safeCount - 1);
        return;
    }
    UObject* controller = find_live(kControllerClass);
    bool ok = call_set_weather(controller, index);
    int after = call_get_weather(controller); // did the set take effect?
    Output::send<LogLevel::Verbose>(
        STR("[Wetterwerk] set_preset({}) dispatched={}, GetCurrentWeather now={}\n"),
        index, ok ? STR("yes") : STR("no"), after);
    if (ok)
    {
        std::lock_guard<std::mutex> lk(m_mutex);
        m_state.index = index;
        if (m_state.hold) m_state.lockedIndex = index;
    }
}

void WeatherControl::cycle(int delta)
{
    int count = m_count_fallback;
    int cur;
    { std::lock_guard<std::mutex> lk(m_mutex); cur = m_state.index; }
    if (cur < 0) cur = 0;
    int target = ((cur + delta) % count + count) % count;
    set_preset(target);
}

void WeatherControl::set_hold(bool on)
{
    UObject* controller = find_live(kControllerClass);
    UObject* weather    = find_live(kWeatherClass);
    std::lock_guard<std::mutex> lk(m_mutex);
    m_state.hold = on;
    if (on)
    {
        int cur = call_get_weather(controller);
        m_state.lockedIndex = (cur >= 0) ? cur : m_state.index;
        set_cycle_flags(controller, weather, false);
    }
    else
    {
        m_state.lockedIndex = -1;
        set_cycle_flags(controller, weather, true);
    }
}

WeatherControl::Snapshot WeatherControl::snapshot()
{
    std::lock_guard<std::mutex> lk(m_mutex);
    return m_state;
}
