"""
#201 Test that the debugger's current line gets
unhighlighted when the DAP client finishes.
"""
import GPS
from gs_utils.internal.utils import *


@run_test_driver
def test_driver():
    # Set a breakpoint on line 5
    buf = GPS.EditorBuffer.get(GPS.File("main.adb"))
    buf.current_view().goto(buf.at(5, 1))
    GPS.execute_action("debug set line breakpoint")
    yield wait_idle()

    # Launch the debugger
    GPS.execute_action("Build & Debug Number 1")
    yield hook("debugger_started")
    yield wait_idle()

    # Continue until we reach the breakpoint
    debug = GPS.Debugger.get()
    yield wait_until_not_busy(debug)
    GPS.execute_action("debug continue")
    yield wait_until_not_busy(debug)

    # Check that the debugger's current line is highlighted
    current_line_msgs = GPS.Message.list(
        category="debugger-current-line", file=GPS.File("main.adb")
    )
    gps_assert(
        len(current_line_msgs) != 0,
        True,
        "The debugger's current line should be highlighted",
    )

    # Close the debugger: check that there is no highlighting anymore
    debug.close()
    yield wait_idle()

    current_line_msgs = GPS.Message.list(
        category="debugger-current-line", file=GPS.File("main.adb")
    )
    gps_assert(
        len(current_line_msgs) == 0,
        True,
        "There should be no debugger's current line highlighting",
    )
