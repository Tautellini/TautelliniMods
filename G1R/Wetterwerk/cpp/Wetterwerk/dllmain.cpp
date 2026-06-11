// dllmain.cpp  --  Wetterwerk, a C++ UE4SS mod (weather control for Gothic 1 Remake)
//
// Thin orchestrator (the analog of main.lua): registers the GUI tab and the
// hotkeys, owns the per-frame on_update pump, and renders. All weather logic and
// the reflection editor live in WeatherControl.
//
// THREADING. UE4SS calls on_update on the game thread and the tab render callback
// on the GUI thread. The render only READS a snapshot and SETS request flags /
// queues edits; on_update consumes them and runs the control on the game thread.
//
// The tab is a full WEATHER EDITOR: preset switching + Hold at the top, then every
// reflected numeric/bool value on the Weather, Sky and Controller actors as an
// editable control (with a filter box). Hotkeys cycle/hold without the GUI.

#include <atomic>
#include <chrono>
#include <cmath>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_map>

#include <Mod/CppUserModBase.hpp>
#include <UE4SSProgram.hpp> // defines UE4SS_ENABLE_IMGUI()
#include <DynamicOutput/DynamicOutput.hpp>

#include <imgui.h>

#include "WeatherControl.hpp"

using namespace RC;

class WetterwerkMod : public CppUserModBase
{
public:
    WetterwerkMod() : CppUserModBase()
    {
        ModName        = STR("Wetterwerk");
        ModVersion     = STR("0.2.0");
        ModDescription = STR("Weather control + full editor for Gothic 1 Remake (Ultra Dynamic Sky).");
        ModAuthors     = STR("Tautellini");

        // conservative until the real count is read from the controller: weathers
        // 0-5 were observed real; higher indices crash (out-of-range). The control
        // also hard-refuses out-of-range sets as a backstop.
        m_control.set_preset_count_fallback(6);

        register_tab(STR("Wetterwerk"), [](CppUserModBase* instance) {
            auto self = dynamic_cast<WetterwerkMod*>(instance);
            if (!self) return;
            self->render_tab();
        });

        // No hotkeys: the menu (the Wetterwerk GUI-console tab) is the only entry
        // point. The Previous/Next/Hold buttons and the value editor drive everything.
        Output::send<LogLevel::Verbose>(STR("Wetterwerk loaded (C++ tab + editor). Menu is the only entry point.\n"));
    }

    ~WetterwerkMod() override = default;

    auto on_ui_init() -> void override
    {
        UE4SS_ENABLE_IMGUI()
    }

    auto on_update() -> void override
    {
        if (int p = m_req_preset.exchange(-1); p >= 0) m_control.set_preset(p);
        if (int c = m_req_cycle.exchange(0); c != 0)   m_control.cycle(c);
        if (int h = m_req_hold.exchange(-1); h >= 0)
        {
            if (h == kHoldToggle) m_control.set_hold(!m_control.snapshot().hold);
            else                  m_control.set_hold(h == kHoldOn);
        }

        m_control.apply_writes();

        // pace: tick fast (responsive editor) while the tab was rendered recently,
        // otherwise a light idle cadence.
        const auto now = std::chrono::steady_clock::now();
        const auto sinceRender = now - tp(m_last_render_ns.load());
        const auto interval = (sinceRender < std::chrono::seconds(1))
            ? std::chrono::milliseconds(100) : std::chrono::milliseconds(400);
        if (now - m_last_tick >= interval)
        {
            m_last_tick = now;
            m_control.tick();
        }
    }

private:
    static constexpr int kHoldOff = 0;
    static constexpr int kHoldOn = 1;
    static constexpr int kHoldToggle = 2;

    static std::chrono::steady_clock::time_point tp(int64_t ns)
    {
        return std::chrono::steady_clock::time_point(std::chrono::nanoseconds(ns));
    }

    static std::string lower(std::string s)
    {
        for (auto& c : s) c = (char)std::tolower((unsigned char)c);
        return s;
    }

    // controls that can DISABLE or OVERRIDE the weather control (cinematic mode,
    // randomize toggles, manual/logic switches). They get pulled into a separate
    // collapsed "Caution" group so they are not toggled by accident (ticking "Use
    // Cinematics Settings" silently stops SetCurrentWeather from working). Matched on
    // the lowercased label.
    static bool is_risky(const std::string& low)
    {
        static const char* terms[] = { "cinematic", "randomize", "enable logic", "manual" };
        for (const char* t : terms)
            if (low.find(t) != std::string::npos) return true;
        return false;
    }

    void render_tab()
    {
        m_last_render_ns.store(std::chrono::steady_clock::now().time_since_epoch().count());
        const WeatherControl::Snapshot s = m_control.snapshot();

        ImGui::Text("Wetterwerk  -  weather control + editor");
        ImGui::Separator();

        if (!s.ready)
        {
            ImGui::Text("Waiting for the world. Be in-game; the weather controller");
            ImGui::Text("is not found yet (load a save or enter the world).");
            return;
        }

        // ---- preset + Hold ----
        if (s.index >= 0) ImGui::Text("Current: %s  (#%d)", s.name.c_str(), s.index);
        else              ImGui::Text("Current: unknown");
        if (!s.leaf.empty()) ImGui::Text("Asset: %s", s.leaf.c_str());

        if (ImGui::Button("< Previous")) m_req_cycle.store(-1);
        ImGui::SameLine();
        if (ImGui::Button("Next >")) m_req_cycle.store(1);
        ImGui::SameLine();
        if (ImGui::Button(s.hold ? "Hold: ON  (release)" : "Hold: OFF  (engage)"))
            m_req_hold.store(kHoldToggle);
        if (s.hold) ImGui::Text("Held. The game will not change the weather.");

        ImGui::Text("Presets:");
        const int count = s.count > 0 ? s.count : 6;
        for (int i = 0; i < count; ++i)
        {
            char label[48];
            std::snprintf(label, sizeof(label), "%d##wp%d", i, i);
            if (ImGui::Button(label)) m_req_preset.store(i);
            if (((i + 1) % 8) != 0 && i < count - 1) ImGui::SameLine();
        }
        ImGui::Separator();

        // ---- the full reflection editor ----
        ImGui::Text("All weather values (%d):", (int)s.knobs.size());
        ImGui::InputText("filter", m_filter, sizeof(m_filter));
        std::string filt = lower(m_filter);

        // scrollable region so the (long) value list always has a draggable
        // scrollbar, even when the host window does not forward the mouse wheel.
        ImGui::BeginChild("##wwscroll", ImVec2(0.0f, 0.0f));
        for (const char* section : { "Weather", "Sky", "Controller" })
        {
            // count visible knobs first so an empty section can collapse quietly
            bool any = false;
            for (const auto& k : s.knobs)
                if (k.section == section) { any = true; break; }
            if (!any) continue;

            if (!ImGui::CollapsingHeader(section)) continue;

            // the actor's own weather variables - editable (risky ones excluded here)
            for (const auto& k : s.knobs)
            {
                if (k.section != section || k.engine) continue;
                if (is_risky(lower(k.label))) continue;
                if (!filt.empty() && lower(k.label).find(filt) == std::string::npos) continue;
                draw_knob(k);
            }

            // risky controls - separate, collapsed, with a warning. Still editable
            // (you may WANT Randomize Weather off, say), just not by accident.
            bool anyRisky = false;
            for (const auto& k : s.knobs)
                if (k.section == section && !k.engine && is_risky(lower(k.label))) { anyRisky = true; break; }
            if (anyRisky)
            {
                std::string node = std::string("(!) Caution - can disable weather control##risk") + section;
                if (ImGui::TreeNode(node.c_str()))
                {
                    ImGui::TextWrapped("These toggle the auto/cinematic/manual logic. "
                        "Changing them can stop preset switching from working "
                        "(e.g. 'Use Cinematics Settings').");
                    for (const auto& k : s.knobs)
                    {
                        if (k.section != section || k.engine || !is_risky(lower(k.label))) continue;
                        if (!filt.empty() && lower(k.label).find(filt) == std::string::npos) continue;
                        draw_knob(k);
                    }
                    ImGui::TreePop();
                }
            }

            // inherited engine properties - read-only, tucked into a sub-dropdown so
            // they do not clutter the real weather knobs
            bool anyEngine = false;
            for (const auto& k : s.knobs)
                if (k.section == section && k.engine) { anyEngine = true; break; }
            if (anyEngine)
            {
                std::string node = std::string("Inherited engine values (read-only)##eng") + section;
                if (ImGui::TreeNode(node.c_str()))
                {
                    for (const auto& k : s.knobs)
                    {
                        if (k.section != section || !k.engine) continue;
                        if (!filt.empty() && lower(k.label).find(filt) == std::string::npos) continue;
                        draw_readonly(k);
                    }
                    ImGui::TreePop();
                }
            }
        }
        ImGui::EndChild();
    }

    // a non-editable value (inherited engine property), shown for reference only
    void draw_readonly(const WeatherControl::Knob& k)
    {
        if (k.kind == 2)      ImGui::Text("%s = %s", k.label.c_str(), k.flag ? "true" : "false");
        else if (k.kind == 1) ImGui::Text("%s = %d", k.label.c_str(), (int)k.num);
        else                  ImGui::Text("%s = %.3f", k.label.c_str(), k.num);
    }

    // draw one editable value; queue a write on change. A small "pending" cache
    // holds the in-progress value so a drag stays smooth until the game-thread
    // read-back catches up.
    void draw_knob(const WeatherControl::Knob& k)
    {
        std::string id = k.section + "/" + k.label;
        std::string widget = k.label + "##" + id;

        if (k.kind == 2) // bool
        {
            auto it = m_pending_bool.find(id);
            bool v = (it != m_pending_bool.end()) ? it->second : k.flag;
            if (ImGui::Checkbox(widget.c_str(), &v))
            {
                m_pending_bool[id] = v;
                WeatherControl::Knob w = k; w.flag = v;
                m_control.queue_write(w);
            }
            else if (it != m_pending_bool.end() && it->second == k.flag)
            {
                m_pending_bool.erase(it); // read-back caught up
            }
            return;
        }

        // numeric: int and float handled separately (DragInt needs an int*)
        auto it = m_pending_num.find(id);
        if (k.kind == 1)
        {
            int iv = (it != m_pending_num.end()) ? (int)it->second : (int)k.num;
            if (ImGui::DragInt(widget.c_str(), &iv))
            {
                m_pending_num[id] = (double)iv;
                WeatherControl::Knob w = k; w.num = (double)iv;
                m_control.queue_write(w);
            }
            else if (it != m_pending_num.end() && (int)it->second == (int)k.num)
            {
                m_pending_num.erase(it);
            }
        }
        else
        {
            float v = (float)((it != m_pending_num.end()) ? it->second : k.num);
            if (ImGui::DragFloat(widget.c_str(), &v, 0.01f))
            {
                m_pending_num[id] = (double)v;
                WeatherControl::Knob w = k; w.num = (double)v;
                m_control.queue_write(w);
            }
            else if (it != m_pending_num.end() && std::abs(it->second - k.num) < 1e-4)
            {
                m_pending_num.erase(it);
            }
        }
    }

    WeatherControl m_control;

    std::atomic<int> m_req_preset{ -1 };
    std::atomic<int> m_req_cycle{ 0 };
    std::atomic<int> m_req_hold{ -1 };

    std::atomic<int64_t> m_last_render_ns{ 0 };
    std::chrono::steady_clock::time_point m_last_tick{};

    char m_filter[64] = { 0 };
    std::unordered_map<std::string, double> m_pending_num;
    std::unordered_map<std::string, bool> m_pending_bool;
};

#define WETTERWERK_API __declspec(dllexport)
extern "C"
{
    WETTERWERK_API RC::CppUserModBase* start_mod()
    {
        return new WetterwerkMod();
    }

    WETTERWERK_API void uninstall_mod(RC::CppUserModBase* mod)
    {
        delete mod;
    }
}
