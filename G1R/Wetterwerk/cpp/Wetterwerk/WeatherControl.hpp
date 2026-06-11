// WeatherControl.hpp  --  the weather control + full reflection editor
//
// Two jobs: (1) the preset/Hold control (find the Ultra Dynamic Sky controller,
// SetCurrentWeatherImmediate, the Hold watchdog), and (2) a REFLECTION EDITOR that
// enumerates EVERY reflected numeric/bool value on the weather actors and lets the
// UI read and write them. The editor recurses one level into structs, so nested
// scalars (color channels, vector axes) are controllable too. This is the C++
// answer to "control every value the game exposes related to weather".
//
// THREADING. tick(), the apply methods and apply_writes() run on the GAME THREAD
// (from the mod's on_update). snapshot() is called from the GUI render thread and
// returns a copy under a mutex; the render never touches a UE object. Edits from
// the render are pushed to a queue (queue_write) and applied on the game thread.

#pragma once

#include <string>
#include <vector>
#include <mutex>
#include <cstdint>

namespace RC::Unreal
{
    class UObject;
    class UStruct;
}

class WeatherControl
{
public:
    // one editable scalar reflected off an actor. `path` is the property chain from
    // the actor down to the scalar (length 1 for a direct property, longer for a
    // value nested inside a struct, e.g. {"Fog Color", "R"}). kind: 0 float, 1 int,
    // 2 bool.
    struct Knob
    {
        std::string section;           // "Weather" / "Sky" / "Controller"
        std::vector<std::string> path; // property path, actor -> ... -> scalar
        std::string label;             // display name (path joined with '.')
        int kind = 0;
        double num = 0.0;              // current value for float/int
        bool flag = false;             // current value for bool
        bool engine = false;           // declared by an engine base class (inherited
                                       // plumbing), not a UDS weather variable -> the
                                       // UI shows these read-only in a sub-dropdown
    };

    struct Snapshot
    {
        bool ready = false;
        bool hold = false;
        int index = -1;
        int lockedIndex = -1;
        int count = 0;
        std::string name = "unknown";
        std::string leaf;
        std::vector<Knob> knobs; // every editable value on the weather actors
    };

    // GAME THREAD
    void tick();             // refresh snapshot (preset + Hold watchdog + all knobs)
    void set_preset(int index);
    void cycle(int delta);
    void set_hold(bool on);
    void apply_writes();     // drain and apply queued edits

    // GUI THREAD
    Snapshot snapshot();
    void queue_write(const Knob& edit);

    void set_preset_count_fallback(int n) { m_count_fallback = n; }

private:
    RC::Unreal::UObject* find_live(const wchar_t* class_name);
    RC::Unreal::UObject* find_actor(const std::string& section);

    bool call_set_weather(RC::Unreal::UObject* controller, int index);
    int  call_get_weather(RC::Unreal::UObject* controller); // -1 if unreadable
    int  read_preset_count(RC::Unreal::UObject* controller); // #ListContainer.Weathers, -1 if unreadable
    void read_preset_name(RC::Unreal::UObject* weather,
                          std::string& out_name, std::string& out_leaf);
    // one-shot diagnostic dump (logged when the controller is (re)acquired)
    void log_diagnostics(RC::Unreal::UObject* controller, RC::Unreal::UObject* weather);
    void set_cycle_flags(RC::Unreal::UObject* controller,
                         RC::Unreal::UObject* weather, bool randomize_on);

    std::mutex m_mutex; // guards m_state
    Snapshot m_state;

    std::mutex m_write_mutex; // guards m_writes
    std::vector<Knob> m_writes;

    int m_count_fallback = 10;
};
