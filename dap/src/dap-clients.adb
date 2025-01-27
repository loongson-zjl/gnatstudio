------------------------------------------------------------------------------
--                               GNAT Studio                                --
--                                                                          --
--                        Copyright (C) 2022-2023, AdaCore                  --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with Ada.Strings.Unbounded;      use Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;

with GNAT.Directory_Operations;  use GNAT.Directory_Operations;
with GNAT.Strings;

with GNATCOLL.Any_Types;
with GNATCOLL.Traces;            use GNATCOLL.Traces;
with GNATCOLL.Utils;

with Spawn.String_Vectors;

with Glib.Object;                use Glib.Object;

with Gtkada.Dialogs;
with Gtkada.MDI;                 use Gtkada.MDI;

with VSS.Characters;             use VSS.Characters;
with VSS.Characters.Latin;
with VSS.JSON.Pull_Readers.Simple;
with VSS.JSON.Push_Writers;
with VSS.Regular_Expressions;
with VSS.Stream_Element_Vectors.Conversions;
with VSS.Strings;                use VSS.Strings;
with VSS.Strings.Conversions;
with VSS.Strings.Cursors.Iterators.Characters;
with VSS.Text_Streams.Memory_UTF8_Input;
with VSS.Text_Streams.Memory_UTF8_Output;

with GPS.Editors;                use GPS.Editors;
with GPS.Kernel;                 use GPS.Kernel;
with GPS.Kernel.MDI;             use GPS.Kernel.MDI;
with GPS.Kernel.Hooks;
with GPS.Kernel.Project;

with LSP.Types;
with LSP.JSON_Streams;

with DAP.Module;
with DAP.Modules.Preferences;
with DAP.Clients.Continue;
with DAP.Clients.Disconnect;
with DAP.Clients.Evaluate;
with DAP.Clients.Initialize;
with DAP.Clients.Stack_Trace;
with DAP.Requests.Disconnect;

with DAP.Views.Consoles;
with DAP.Tools.Inputs;
with DAP.Utils;                  use DAP.Utils;

with Interactive_Consoles;       use Interactive_Consoles;
with GUI_Utils;
with Language_Handlers;          use Language_Handlers;
with Toolchains;                 use Toolchains;
with Remote;

package body DAP.Clients is

   Me      : constant Trace_Handle := Create ("GPS.DAP.Clients", On);
   DAP_Log : constant GNATCOLL.Traces.Trace_Handle :=
     Create ("GPS.DAP.IN_OUT", Off);

   procedure Free is new Ada.Unchecked_Deallocation
     (DAP.Modules.Breakpoint_Managers.DAP_Client_Breakpoint_Manager'Class,
      DAP.Modules.Breakpoint_Managers.DAP_Client_Breakpoint_Manager_Access);

   procedure Free is new Ada.Unchecked_Deallocation
     (DAP.Clients.Stack_Trace.Stack_Trace'Class,
      DAP.Clients.Stack_Trace.Stack_Trace_Access);

   Is_Quit_Pattern : constant VSS.Regular_Expressions.
     Regular_Expression := VSS.Regular_Expressions.To_Regular_Expression
       ("^\s*(quit|qui|q|-gdb-exit)\s*$");
   --  'qu' can be quit or queue-signal

   Is_Frame_Up_Pattern : constant VSS.Regular_Expressions.
     Regular_Expression := VSS.Regular_Expressions.To_Regular_Expression
       ("^\s*(up)\s*$");

   Is_Frame_Down_Pattern : constant VSS.Regular_Expressions.
     Regular_Expression := VSS.Regular_Expressions.To_Regular_Expression
       ("^\s*(down)\s*$");

   Is_Frame_Pattern : constant VSS.Regular_Expressions.
     Regular_Expression := VSS.Regular_Expressions.To_Regular_Expression
       ("^\s*(?:frame)\s*(\d+)\s*$");

   Is_Catch_Exception_Pattern : constant VSS.Regular_Expressions.
     Regular_Expression := VSS.Regular_Expressions.To_Regular_Expression
       ("^\s*(catch|tcatch)\s+(exception)\s*$");

   Is_Breakpoint_Pattern : constant VSS.Regular_Expressions.
     Regular_Expression := VSS.Regular_Expressions.To_Regular_Expression
       ("^\s*(?:(break|b)|(tbreak|tb)|(hbreak|thbreak|rbreak|thb|hb|rb))"
        & "(?:\s+(.+)?)?$");
   --  to catch breakpoint command

   Is_Continue_Pattern : constant VSS.Regular_Expressions.
     Regular_Expression := VSS.Regular_Expressions.To_Regular_Expression
       ("^\s*(?:continue|c|fg)\s*$");
   --  to catch the `continue` command in the console

   --  Bp_Regular_Idx       : constant := 1;
   Bp_Temporary_Idx     : constant := 2;
   Bp_Not_Supported_Idx : constant := 3;
   Bp_Details_Idx       : constant := 4;

   Breakpoint_Details_Pattern : constant VSS.Regular_Expressions.
     Regular_Expression := VSS.Regular_Expressions.To_Regular_Expression
       ("^(?:(?:([+-])(\d+))|(?:\*(0x[0-9a-f]+))|(?:(?:((?:\S:)?\S+):)?"
        & "(?:(\d+)|(\w+))))?(?:\s*if\s+(.+))?$");
   --  breakpoint command details like file/line, address and so on

   Bp_Offset_Sig_Idx : constant := 1;
   Bp_Offset_Idx     : constant := 2;
   Bp_Address_Idx    : constant := 3;
   Bp_File_Idx       : constant := 4;
   Bp_Line_Idx       : constant := 5;
   Bp_Subprogram_Idx : constant := 6;
   Bp_Condition_Idx  : constant := 7;

   ------------------
   -- Allocate_TTY --
   ------------------

   procedure Allocate_TTY (Self : in out DAP_Client) is
   begin
      GNAT.TTY.Allocate_TTY (Self.Debuggee_TTY);
   end Allocate_TTY;

   ---------------
   -- Close_TTY --
   ---------------

   procedure Close_TTY (Self : in out DAP_Client) is
   begin
      GNAT.TTY.Close_TTY (Self.Debuggee_TTY);
   end Close_TTY;

   --------------
   -- On_Error --
   --------------

   overriding procedure On_Error
     (Self  : in out DAP_Client;
      Error : String) is
   begin
      Trace (Me, "On_Error:" & Error);
      Self.Reject_All_Requests;
   end On_Error;

   -------------------------------
   -- On_Standard_Error_Message --
   -------------------------------

   overriding procedure On_Standard_Error_Message
     (Self : in out DAP_Client;
      Text : String)
   is
      pragma Unreferenced (Self);
   begin
      Trace (Me, "On_Standard_Error_Message:" & Text);
   end On_Standard_Error_Message;

   ------------------
   -- On_Exception --
   ------------------

   overriding procedure On_Exception
     (Self       : in out DAP_Client;
      Occurrence : Ada.Exceptions.Exception_Occurrence)
   is
      pragma Unreferenced (Self);
   begin
      Trace (Me, Occurrence);
   end On_Exception;

   ---------------------
   -- Break_Exception --
   ---------------------

   procedure Break_Exception
     (Self      : in out DAP_Client;
      Name      : String;
      Unhandled : Boolean := False;
      Temporary : Boolean := False)
   is
      use DAP.Modules.Breakpoint_Managers;
   begin
      if Self.Breakpoints /= null then
         Break_Exception (Self.Breakpoints, Name, Unhandled, Temporary);
      end if;
   end Break_Exception;

   -----------
   -- Break --
   -----------

   procedure Break
     (Self : in out DAP_Client;
      Data : DAP.Modules.Breakpoints.Breakpoint_Data)
   is
      use DAP.Modules.Breakpoint_Managers;
      D : DAP.Modules.Breakpoints.Breakpoint_Data := Data;
   begin
      if Self.Breakpoints /= null then
         D.Executable := Self.Get_Executable;
         Break (Self.Breakpoints, D);
      end if;
   end Break;

   ------------------
   -- Break_Source --
   ------------------

   procedure Break_Source
     (Self      : in out DAP_Client;
      File      : GNATCOLL.VFS.Virtual_File;
      Line      : Editable_Line_Type;
      Temporary : Boolean := False;
      Condition : VSS.Strings.Virtual_String :=
        VSS.Strings.Empty_Virtual_String)
   is
      use DAP.Modules.Breakpoint_Managers;
   begin
      if Self.Breakpoints /= null then
         Break_Source (Self.Breakpoints, File, Line, Temporary, Condition);
      end if;
   end Break_Source;

   ----------------------
   -- Break_Subprogram --
   ----------------------

   procedure Break_Subprogram
     (Self       : in out DAP_Client;
      Subprogram : String;
      Temporary  : Boolean := False;
      Condition  : VSS.Strings.Virtual_String :=
        VSS.Strings.Empty_Virtual_String)
   is
      use DAP.Modules.Breakpoint_Managers;
   begin
      if Self.Breakpoints /= null then
         Break_Subprogram (Self.Breakpoints, Subprogram, Temporary, Condition);
      end if;
   end Break_Subprogram;

   -------------------
   -- Break_Address --
   -------------------

   procedure Break_Address
     (Self      : in out DAP_Client;
      Address   : Address_Type;
      Temporary : Boolean := False;
      Condition : VSS.Strings.Virtual_String :=
        VSS.Strings.Empty_Virtual_String)
   is
      use DAP.Modules.Breakpoint_Managers;
   begin
      if Self.Breakpoints /= null then
         Break_Address (Self.Breakpoints, Address, Temporary, Condition);
      end if;
   end Break_Address;

   -----------------------------------
   -- Toggle_Instruction_Breakpoint --
   -----------------------------------

   procedure Toggle_Instruction_Breakpoint
     (Self    : in out DAP_Client;
      Address : Address_Type)
   is
      use DAP.Modules.Breakpoint_Managers;
   begin
      if Self.Breakpoints /= null then
         Toggle_Instruction_Breakpoint (Self.Breakpoints, Address);
      end if;
   end Toggle_Instruction_Breakpoint;

   --------------------------
   -- Remove_Breakpoint_At --
   --------------------------

   procedure Remove_Breakpoint_At
     (Self      : in out DAP_Client;
      File      : GNATCOLL.VFS.Virtual_File;
      Line      : Editable_Line_Type)
   is
      use DAP.Modules.Breakpoint_Managers;
   begin
      if Self.Breakpoints /= null then
         Remove_Breakpoint_At (Self.Breakpoints, File, Line);
      end if;
   end Remove_Breakpoint_At;

   ------------------------
   -- Remove_Breakpoints --
   ------------------------

   procedure Remove_Breakpoints
     (Self : in out DAP_Client;
      List : DAP.Types.Breakpoint_Identifier_Lists.List)
   is
      use DAP.Modules.Breakpoint_Managers;
   begin
      if Self.Breakpoints /= null then
         Remove_Breakpoints (Self.Breakpoints, List);
      end if;
   end Remove_Breakpoints;

   ----------------------------
   -- Remove_All_Breakpoints --
   ----------------------------

   procedure Remove_All_Breakpoints (Self : in out DAP_Client) is
      use DAP.Modules.Breakpoint_Managers;
   begin
      if Self.Breakpoints /= null then
         Remove_All_Breakpoints (Self.Breakpoints);
      end if;
   end Remove_All_Breakpoints;

   --------------------
   -- Has_Breakpoint --
   --------------------

   function Has_Breakpoint
     (Self   : DAP_Client;
      Marker : GPS.Markers.Location_Marker)
      return Boolean
   is
      use DAP.Modules.Breakpoint_Managers;
   begin
      if Self.Breakpoints /= null then
         return Has_Breakpoint (Self.Breakpoints, Marker);
      else
         return False;
      end if;
   end Has_Breakpoint;

   -----------------------
   -- Initialize_Client --
   -----------------------

   procedure Initialize_Client (Self : not null access DAP_Client) is
   begin
      Self.Visual := new DAP_Visual_Debugger'
        (Glib.Object.GObject_Record with Client => Self.This);
      Glib.Object.Initialize (Self.Visual);
      Ref (Self.Visual);
      Self.Stack_Trace := DAP.Clients.Stack_Trace.Stack_Trace_Access'
        (new DAP.Clients.Stack_Trace.Stack_Trace);
   end Initialize_Client;

   ----------------
   -- Is_Stopped --
   ----------------

   function Is_Stopped (Self : DAP_Client) return Boolean is
   begin
      return Self.Status = Stopped;
   end Is_Stopped;

   --------------
   -- Is_Ready --
   --------------

   function Is_Ready (Self : DAP_Client) return Boolean is
   begin
      return Self.Status = Ready;
   end Is_Ready;

   --------------------------
   -- Is_Ready_For_Command --
   --------------------------

   function Is_Ready_For_Command (Self : DAP_Client) return Boolean is
   begin
      return Self.Status in Ready .. Stopped
        and then Self.Sent.Is_Empty;
   end Is_Ready_For_Command;

   ---------------------
   -- Is_Quit_Command --
   ---------------------

   function Is_Quit_Command
     (Self : DAP_Client;
      Cmd  : Virtual_String)
      return Boolean
   is
      pragma Unreferenced (Self);
   begin
      return Is_Quit_Pattern.Match (Cmd).Has_Match;
   end Is_Quit_Command;

   -------------------------
   -- Is_Frame_Up_Command --
   -------------------------

   function Is_Frame_Up_Command
     (Self : DAP_Client;
      Cmd  : Virtual_String)
      return Boolean
   is
      pragma Unreferenced (Self);
   begin
      return Is_Frame_Up_Pattern.Match (Cmd).Has_Match;
   end Is_Frame_Up_Command;

   ---------------------------
   -- Is_Frame_Down_Command --
   ---------------------------

   function Is_Frame_Down_Command
     (Self : DAP_Client;
      Cmd  : Virtual_String)
      return Boolean
   is
      pragma Unreferenced (Self);
   begin
      return Is_Frame_Down_Pattern.Match (Cmd).Has_Match;
   end Is_Frame_Down_Command;

   ----------------------
   -- Is_Frame_Command --
   ----------------------

   function Is_Frame_Command
     (Self  : DAP_Client;
      Cmd   : VSS.Strings.Virtual_String;
      Level : out Integer)
      return Boolean
   is
      pragma Unreferenced (Self);
      Matched : VSS.Regular_Expressions.Regular_Expression_Match;
   begin
      Matched := Is_Frame_Pattern.Match (Cmd);
      if Matched.Has_Capture (1) then
         Level := Integer'Value
           (VSS.Strings.Conversions.To_UTF_8_String (Matched.Captured (1)));
         return True;
      else
         return False;
      end if;
   end Is_Frame_Command;

   ----------------------
   -- Set_Capabilities --
   ----------------------

   procedure Set_Capabilities
     (Self         : in out DAP_Client;
      Capabilities : DAP.Tools.Optional_Capabilities) is
   begin
      Self.Capabilities := Capabilities;
   end Set_Capabilities;

   ----------------------
   -- Get_Capabilities --
   ----------------------

   function Get_Capabilities
     (Self : in out DAP_Client)
      return DAP.Tools.Optional_Capabilities is
   begin
      return Self.Capabilities;
   end Get_Capabilities;

   ----------------
   -- Set_Status --
   ----------------

   procedure Set_Status
     (Self   : in out DAP_Client'Class;
      Status : Debugger_Status_Kind)
   is
      use type Generic_Views.Abstract_View_Access;

      Old : constant Debugger_Status_Kind := Self.Status;
   begin
      if Self.Status = Status
        or else Self.Status = Terminating
      then
         return;
      end if;

      Self.Status := Status;

      if Self.Status not in Ready .. Stopped then
         if Self.Stack_Trace /= null then
            Self.Get_Stack_Trace.Clear;
         end if;
         Self.Selected_Thread := 0;

         DAP.Utils.Unhighlight_Current_Line (Self.Kernel);
      end if;

      case Self.Status is
         when Ready =>
            if Self.Debuggee_Console = null then
               DAP.Views.Consoles.Create_Execution_Console (Self.This);
            end if;

            --  Trigger this hook when we did all preparations
            --  (for example set breakpoints). In either case we will
            --  have the mess with debugging
            GPS.Kernel.Hooks.Debugger_Started_Hook.Run
              (Self.Kernel, Self.Visual);

         when Stopped =>
            GPS.Kernel.Hooks.Debugger_Process_Stopped_Hook.Run
              (Self.Kernel, Self.Visual);

            --  Inform that location has changed
            GPS.Kernel.Hooks.Debugger_Location_Changed_Hook.Run
              (Self.Kernel, Self.Visual);

         when Terminating =>
            if Debugger_Status_Kind'Pos (Old) >=
              Debugger_Status_Kind'Pos (Initialized)
            then
               GPS.Kernel.Hooks.Debugger_Terminated_Hook.Run
                 (Self.Kernel, Self.Get_Visual);
            end if;

         when others =>
            null;
      end case;

      GPS.Kernel.Hooks.Debugger_State_Changed_Hook.Run
        (Self.Kernel, Self.Visual,
         (case Self.Status is
             when Terminating | Initialization =>
               GPS.Debuggers.Debug_None,
             when  Initialized .. Stopped      =>
               GPS.Debuggers.Debug_Available,
             when others                       =>
               GPS.Debuggers.Debug_Busy));

      Self.Kernel.Refresh_Context;
   end Set_Status;

   -------------
   -- Enqueue --
   -------------

   procedure Enqueue
     (Self    : in out DAP_Client;
      Request : in out DAP.Requests.DAP_Request_Access;
      Force   : Boolean := False) is
   begin
      if Force
        or else Self.Status in Initialization .. Stopped
      then
         Self.Process (Request);

      else
         Request.On_Rejected (Self'Access);
         DAP.Requests.Destroy (Request);
      end if;

      Request := null;
   end Enqueue;

   --------------------------
   -- Get_Debuggee_Console --
   --------------------------

   function Get_Debuggee_Console
     (Self : DAP_Client)
      return Generic_Views.Abstract_View_Access is
   begin
      return Self.Debuggee_Console;
   end Get_Debuggee_Console;

   ----------------------
   -- Get_Debuggee_TTY --
   ----------------------

   function Get_Debuggee_TTY
     (Self : DAP_Client)
      return GNAT.TTY.TTY_Handle is
   begin
      return Self.Debuggee_TTY;
   end Get_Debuggee_TTY;

   ---------------------
   -- Get_Breakpoints --
   ---------------------

   function Get_Breakpoints
     (Self : DAP_Client)
      return DAP.Modules.Breakpoints.Breakpoint_Vectors.Vector
   is
      use type DAP.Modules.Breakpoint_Managers.
        DAP_Client_Breakpoint_Manager_Access;

      Empty : DAP.Modules.Breakpoints.Breakpoint_Vectors.Vector;
   begin
      if Self.Breakpoints /= null then
         return Self.Breakpoints.Get_Breakpoints;
      else
         return Empty;
      end if;
   end Get_Breakpoints;

   -------------------------
   -- Get_Command_History --
   -------------------------

   function Get_Command_History
     (Self : in out DAP_Client)
      return History_List_Access is
   begin
      return Self.Command_History'Unchecked_Access;
   end Get_Command_History;

   --------------------------
   -- Get_Debugger_Console --
   --------------------------

   function Get_Debugger_Console
     (Self : DAP_Client)
      return Generic_Views.Abstract_View_Access is
   begin
      return Self.Debugger_Console;
   end Get_Debugger_Console;

   --------------------------
   -- Set_Debugger_Console --
   --------------------------

   procedure Set_Debugger_Console
     (Self    : in out DAP_Client;
      Console : Generic_Views.Abstract_View_Access) is
   begin
      Self.Debugger_Console := Console;
   end Set_Debugger_Console;

   ------------------------
   -- Get_Current_Thread --
   ------------------------

   function Get_Current_Thread (Self  : in out DAP_Client) return Integer is
   begin
      if Self.Stopped_Threads.Is_Empty then
         return 0;
      end if;

      --  TODO: doc
      if Self.Selected_Thread /= 0 then
         return Self.Selected_Thread;
      else
         return Self.Stopped_Threads.Element (Self.Stopped_Threads.First);
      end if;
   end Get_Current_Thread;

   --------------------
   -- Get_Executable --
   --------------------

   function Get_Executable
     (Self : in out DAP_Client) return GNATCOLL.VFS.Virtual_File is
   begin
      return Self.Executable;
   end Get_Executable;

   -----------------
   -- Get_Project --
   -----------------

   function Get_Project
     (Self : in out DAP_Client) return GNATCOLL.Projects.Project_Type is
   begin
      return Self.Project;
   end Get_Project;

   -------------------------
   -- Get_Executable_Args --
   -------------------------

   function Get_Executable_Args
     (Self : in out DAP_Client) return Ada.Strings.Unbounded.Unbounded_String
   is
   begin
      return Self.Executable_Args;
   end Get_Executable_Args;

   ---------------------
   -- Get_Endian_Type --
   ---------------------

   function Get_Endian_Type (Self : in out DAP_Client) return Endian_Type is
   begin
      return Self.Endian;
   end Get_Endian_Type;

   --------------------
   -- Set_Executable --
   --------------------

   procedure Set_Executable
     (Self : in out DAP_Client;
      File : GNATCOLL.VFS.Virtual_File) is
   begin
      Self.Executable := File;
   end Set_Executable;

   --------------------------
   -- Set_Debuggee_Console --
   --------------------------

   procedure Set_Debuggee_Console
     (Self : in out DAP_Client;
      View : Generic_Views.Abstract_View_Access) is
   begin
      Self.Debuggee_Console := View;
   end Set_Debuggee_Console;

   ---------------------------
   -- Set_Breakpoints_State --
   ---------------------------

   procedure Set_Breakpoints_State
     (Self  : in out DAP_Client;
      List  : Breakpoint_Identifier_Lists.List;
      State : Boolean)
   is
      use type DAP.Modules.Breakpoint_Managers.
        DAP_Client_Breakpoint_Manager_Access;
   begin
      if Self.Breakpoints /= null then
         DAP.Modules.Breakpoint_Managers.Set_Breakpoints_State
           (Self.Breakpoints, List, State);
      end if;
   end Set_Breakpoints_State;

   -------------
   -- Set_TTY --
   -------------

   procedure Set_TTY
     (Self : in out DAP_Client;
      TTY  : String)
   is
      Req : DAP.Requests.DAP_Request_Access;
   begin
      if TTY /= "" then
         Req := DAP.Requests.DAP_Request_Access
           (DAP.Clients.Evaluate.Create_Set_TTY (Self, TTY));
         Self.Enqueue (Req);
      end if;
   end Set_TTY;

   ------------------------
   -- Set_Selected_Frame --
   ------------------------

   procedure Set_Selected_Frame
     (Self : in out DAP_Client;
      Id   : Integer) is
   begin
      Self.Get_Stack_Trace.Select_Frame (Id, Self'Access);
   end Set_Selected_Frame;

   -------------------------
   -- Set_Selected_Thread --
   -------------------------

   procedure Set_Selected_Thread (Self : in out DAP_Client; Id : Integer) is
   begin
      Self.Selected_Thread := Id;
      GPS.Kernel.Hooks.Debugger_Frame_Changed_Hook.Run
        (Self.Kernel, Self.Visual);
   end Set_Selected_Thread;

   ----------------------
   -- Set_Source_Files --
   ----------------------

   procedure Set_Source_Files
     (Self         : in out DAP_Client;
      Source_Files : VSS.String_Vectors.Virtual_String_Vector) is
   begin
      Self.Source_Files := Source_Files;
   end Set_Source_Files;

   --------------------
   -- Get_Request_ID --
   --------------------

   function Get_Request_ID
     (Self : in out DAP_Client) return Integer
   is
      ID : constant Integer := Self.Request_Id;
   begin
      if Self.Request_Id < Integer'Last then
         Self.Request_Id := Self.Request_Id + 1;
      else
         Self.Request_Id := 1;
      end if;

      return ID;
   end Get_Request_ID;

   ----------------
   -- Get_Status --
   ----------------

   function Get_Status
     (Self : in out DAP_Client) return Debugger_Status_Kind is
   begin
      return Self.Status;
   end Get_Status;

   ----------------
   -- Get_Visual --
   ----------------

   function Get_Visual
     (Self : in out DAP_Client)
      return DAP_Visual_Debugger_Access is
   begin
      return Self.Visual;
   end Get_Visual;

   ------------------
   -- Current_File --
   ------------------

   function Current_File
     (Visual : not null access DAP_Visual_Debugger)
      return GNATCOLL.VFS.Virtual_File is
   begin
      return Visual.Client.Get_Stack_Trace.Get_Current_File;
   end Current_File;

   ------------------
   -- Current_Line --
   ------------------

   function Current_Line
     (Visual : not null access DAP_Visual_Debugger)
      return Natural is
   begin
      return Visual.Client.Get_Stack_Trace.Get_Current_Line;
   end Current_Line;

   -------------------
   -- Error_Message --
   -------------------

   overriding function Error_Message
     (Self : DAP_Client) return VSS.Strings.Virtual_String is
   begin
      return Self.Error_Msg;
   end Error_Message;

   -------------------
   -- On_Configured --
   -------------------

   procedure On_Configured (Self : in out DAP_Client) is
   begin
      Self.Set_Status (Running);
   end On_Configured;

   ------------------------
   -- On_Breakpoints_Set --
   ------------------------

   procedure On_Breakpoints_Set (Self : in out DAP_Client) is
      Req : DAP.Requests.DAP_Request_Access := DAP.Requests.DAP_Request_Access
        (DAP.Clients.Evaluate.Create_Show_Endian (Self));
   begin
      Self.Enqueue (Req);
   end On_Breakpoints_Set;

   -----------------
   -- On_Continue --
   -----------------

   procedure On_Continue (Self : in out DAP_Client) is
   begin
      Self.Set_Status (Running);
   end On_Continue;

   -----------------
   -- On_Finished --
   -----------------

   overriding procedure On_Finished (Self : in out DAP_Client)
   is
      use type DAP.Modules.Breakpoint_Managers.
        DAP_Client_Breakpoint_Manager_Access;

   begin
      if Self.Visual = null then
         return;
      end if;

      if Self.Breakpoints /= null then
         Self.Breakpoints.Finalize;
         Free (Self.Breakpoints);
      end if;

      Unref (Self.Visual);
      Self.Visual := null;

      DAP.Module.Finished (Self.Id);
   exception
      when E : others =>
         Trace (Me, E);
   end On_Finished;

   ----------------------------------
   -- Load_Project_From_Executable --
   ----------------------------------

   procedure Load_Project_From_Executable (Self : in out DAP_Client) is
      use GNAT.Strings;
      use GNATCOLL.Projects;
      use GNATCOLL.VFS;
      use Gtkada.Dialogs;
      use GPS.Kernel.Project;

      Project : GNATCOLL.Projects.Project_Type := Get_Project (Self.Kernel);
   begin
      --  Do nothing unless the current project was already generated from an
      --  executable.

      if Get_Registry (Self.Kernel).Tree.Status /= From_Executable then
         return;
      end if;

      if Self.Executable /= No_File
        and then not Is_Regular_File (Self.Get_Executable)
      then
         declare
            Buttons : Message_Dialog_Buttons;
            pragma Unreferenced (Buttons);
         begin
            Buttons := GUI_Utils.GPS_Message_Dialog
              (Msg         =>
                 "The executable specified with" &
                   " --debug does not exist on disk",
               Dialog_Type => Error,
               Buttons     => Button_OK,
               Title       => "Executable not found",
               Parent      => GPS.Kernel.Get_Main_Window (Self.Kernel));
         end;
      end if;

      declare
         List : GNAT.Strings.String_List_Access :=
           Project.Attribute_Value (Main_Attribute);
      begin
         if List /= null then
            for L in List'Range loop
               if Equal (+List (L).all, Full_Name (Self.Executable)) then
                  Free (List);
                  return;
               end if;
            end loop;
            Free (List);
         end if;
      end;

      --  No handling of desktop is done here, we want to leave all windows
      --  as-is.

      Get_Registry (Self.Kernel).Tree.Unload;

      --  Create an empty project, and we'll add properties to it

      if Self.Executable /= No_File then
         Get_Registry (Self.Kernel).Tree.Load_Empty_Project
           (Get_Registry (Self.Kernel).Environment,
            Name           => "debugger_" & (+Base_Name (Self.Get_Executable)),
            Recompute_View => False);
      else
         Get_Registry (Self.Kernel).Tree.Load_Empty_Project
           (Get_Registry (Self.Kernel).Environment,
            Name           => "debugger_no_file",
            Recompute_View => False);
      end if;

      Project := Get_Registry (Self.Kernel).Tree.Root_Project;

      declare
         Bases       : GNAT.OS_Lib.Argument_List
           (1 .. Self.Source_Files.Length);
         Bases_Index : Natural := Bases'First;
         Dirs        : GNAT.OS_Lib.Argument_List
           (1 .. Self.Source_Files.Length);
         Dirs_Index  : Natural := Dirs'First;
         Main        : GNAT.OS_Lib.Argument_List (1 .. 1);
         Langs       : GNAT.OS_Lib.Argument_List
           (1 .. Self.Source_Files.Length);
         Lang_Index  : Natural := Langs'First;

      begin
         --  Source_Files, Source_Dirs & Languages

         for L in 1 .. Self.Source_Files.Length loop
            declare
               Remote_File : constant Virtual_File :=
                 Create_From_Base
                   (+UTF8 (Self.Source_Files.Element (L)),
                    Dir_Name (Self.Get_Executable),
                    Remote.Get_Nickname (Remote.Debug_Server));
               Local_File  : constant Virtual_File := To_Local (Remote_File);
               Dir         : constant Virtual_File := Local_File.Dir;
               Base        : constant Filesystem_String :=
                 Base_Name (Local_File);
               Lang        : constant String :=
                 Get_Language_From_File
                   (GPS.Kernel.Get_Language_Handler (Self.Kernel),
                    Local_File);
               Found       : Boolean;

            begin
               Found := False;

               if Is_Directory (Dir) then
                  for D in Dirs'First .. Dirs_Index - 1 loop
                     if Equal (+Dirs (D).all, Dir.Full_Name) then
                        Found := True;
                        exit;
                     end if;
                  end loop;

                  if not Found then
                     Dirs (Dirs_Index) := new String'(+Dir.Full_Name);
                     Dirs_Index := Dirs_Index + 1;
                  end if;

                  Found := False;
                  for J in Bases'First .. Bases_Index - 1 loop
                     if Equal (+Bases (J).all, Base) then
                        Found := True;
                        exit;
                     end if;
                  end loop;

                  if not Found then
                     Bases (Bases_Index) := new String'
                       (Base_Name (UTF8 (Self.Source_Files.Element (L))));
                     Bases_Index := Bases_Index + 1;
                  end if;

                  Found := False;
                  if Lang /= "" then
                     for La in Langs'First .. Lang_Index - 1 loop
                        if Langs (La).all = Lang then
                           Found := True;
                           exit;
                        end if;
                     end loop;

                     if not Found then
                        Langs (Lang_Index) := new String'(Lang);
                        Lang_Index := Lang_Index + 1;
                     end if;
                  end if;
               end if;
            end;
         end loop;

         GNATCOLL.Traces.Trace (Me, "Setting Source_Dirs:");
         for D in Dirs'First .. Dirs_Index - 1 loop
            GNATCOLL.Traces.Trace (Me, "   " & Dirs (D).all);
         end loop;

         Project.Set_Attribute
           (Attribute          => Source_Dirs_Attribute,
            Values             => Dirs (Dirs'First .. Dirs_Index - 1));
         GNATCOLL.Utils.Free (Dirs);

         GNATCOLL.Traces.Trace (Me, "Setting Source_Files:");
         for B in Bases'First .. Bases_Index - 1 loop
            GNATCOLL.Traces.Trace (Me, "   " & Bases (B).all);
         end loop;

         Project.Set_Attribute
           (Attribute          => Source_Files_Attribute,
            Values             => Bases (Bases'First .. Bases_Index - 1));
         GNATCOLL.Utils.Free (Bases);

         GNATCOLL.Traces.Trace (Me, "Setting Languages:");
         for L in Langs'First .. Lang_Index - 1 loop
            GNATCOLL.Traces.Trace (Me, "   " & Langs (L).all);
         end loop;

         if Lang_Index = Langs'First then
            Project.Set_Attribute
              (Scenario  => All_Scenarios,
               Attribute => Languages_Attribute,
               Values    =>
                 (new String'("ada"), new String'("c"), new String'("c++")));
         else
            Project.Set_Attribute
              (Attribute          => Languages_Attribute,
               Values             => Langs (Langs'First .. Lang_Index - 1));
         end if;

         GNATCOLL.Utils.Free (Langs);

         --  Object_Dir, Exec_Dir, Main

         if Self.Executable /= No_File then
            Project.Set_Attribute
              (Attribute          => Obj_Dir_Attribute,
               Value              => +Dir_Name (Self.Get_Executable));
            Project.Set_Attribute
              (Attribute          => Exec_Dir_Attribute,
               Value              => +Dir_Name (Self.Get_Executable));

            Main (Main'First) := new String'(+Full_Name (Self.Executable));
            Project.Set_Attribute
              (Attribute          => Main_Attribute,
               Values             => Main);
            GNATCOLL.Utils.Free (Main);
         end if;
      end;

      --  Is the information for this executable already cached? If yes,
      --  we simply reuse it to avoid the need to interact with the debugger.

      Project.Set_Modified (False);
      Get_Registry (Self.Kernel).Tree.Set_Status (From_Executable);
      GPS.Kernel.Hooks.Project_Changed_Hook.Run (Self.Kernel);
      Recompute_View (Self.Kernel);
   end Load_Project_From_Executable;

   -----------------
   -- On_Launched --
   -----------------

   procedure On_Launched (Self : in out DAP_Client) is
   begin
      if not Self.Source_Files.Is_Empty then
         Self.Load_Project_From_Executable;
      end if;

      --  Show Main file when 'info line' command is in the protocol

      Self.Breakpoints := new DAP.Modules.Breakpoint_Managers.
        DAP_Client_Breakpoint_Manager (Self.Kernel, Self.This);
      DAP.Modules.Breakpoint_Managers.Initialize (Self.Breakpoints);
   end On_Launched;

   --------------------
   -- On_Raw_Message --
   --------------------

   overriding procedure On_Raw_Message
     (Self    : in out DAP_Client;
      Data    : Ada.Strings.Unbounded.Unbounded_String;
      Success : in out Boolean)
   is
      pragma Unreferenced (Success);
      use type DAP.Requests.DAP_Request_Access;

      procedure Look_Ahead
        (Seq         : out LSP.Types.LSP_Number;
         Request_Seq : out Integer;
         A_Type      : out VSS.Strings.Virtual_String;
         Success     : out LSP.Types.Optional_Boolean;
         Message     : in out VSS.Strings.Virtual_String;
         Event       : in out VSS.Strings.Virtual_String);

      Memory : aliased
        VSS.Text_Streams.Memory_UTF8_Input.Memory_UTF8_Input_Stream;

      ----------------
      -- Look_Ahead --
      ----------------

      procedure Look_Ahead
        (Seq         : out LSP.Types.LSP_Number;
         Request_Seq : out Integer;
         A_Type      : out VSS.Strings.Virtual_String;
         Success     : out LSP.Types.Optional_Boolean;
         Message     : in out VSS.Strings.Virtual_String;
         Event       : in out VSS.Strings.Virtual_String)
      is

         Reader : aliased
           VSS.JSON.Pull_Readers.Simple.JSON_Simple_Pull_Reader;
         JS     : aliased LSP.JSON_Streams.JSON_Stream
           (False, Reader'Access);

      begin
         Seq         := 0;
         Request_Seq := 0;
         A_Type      := VSS.Strings.Empty_Virtual_String;
         Success     := (Is_Set => False);

         Reader.Set_Stream (Memory'Unchecked_Access);
         JS.R.Read_Next;
         pragma Assert (JS.R.Is_Start_Document);
         JS.R.Read_Next;
         pragma Assert (JS.R.Is_Start_Object);
         JS.R.Read_Next;

         while not JS.R.Is_End_Object loop
            pragma Assert (JS.R.Is_Key_Name);
            declare
               Key : constant String := UTF8 (JS.R.Key_Name);

            begin
               JS.R.Read_Next;

               if Key = "seq" then
                  pragma Assert (JS.R.Is_Number_Value);
                  Seq := LSP.Types.LSP_Number
                    (JS.R.Number_Value.Integer_Value);

                  JS.R.Read_Next;

               elsif Key = "request_seq" then
                  pragma Assert (JS.R.Is_Number_Value);
                  Request_Seq := Integer (JS.R.Number_Value.Integer_Value);

                  JS.R.Read_Next;

               elsif Key = "type" then
                  pragma Assert (JS.R.Is_String_Value);

                  A_Type := JS.R.String_Value;

                  JS.R.Read_Next;

               elsif Key = "success" then
                  pragma Assert (JS.R.Is_Boolean_Value);

                  Success := (True, JS.R.Boolean_Value);

                  JS.R.Read_Next;

               elsif Key = "message" then
                  pragma Assert (JS.R.Is_String_Value);

                  Message := JS.R.String_Value;

                  JS.R.Read_Next;

               elsif Key = "event" then
                  pragma Assert (JS.R.Is_String_Value);

                  Event := JS.R.String_Value;

                  JS.R.Read_Next;

               else
                  JS.Skip_Value;
               end if;
            end;
         end loop;

         Memory.Rewind;
      end Look_Ahead;

      Reader : aliased VSS.JSON.Pull_Readers.Simple.JSON_Simple_Pull_Reader;
      Stream : aliased LSP.JSON_Streams.JSON_Stream
        (Is_Server_Side => False, R => Reader'Access);

      Seq         : LSP.Types.LSP_Number;
      A_Type      : VSS.Strings.Virtual_String;
      Request_Seq : Integer;
      R_Success   : LSP.Types.Optional_Boolean;
      Message     : VSS.Strings.Virtual_String;
      Event       : VSS.Strings.Virtual_String;

      Position    : Requests_Maps.Cursor;
      Request     : DAP.Requests.DAP_Request_Access;
      New_Request : DAP.Requests.DAP_Request_Access := null;

   begin
      if DAP_Log.Is_Active then
         Trace (DAP_Log, "[" & Self.Id'Img & "<-]" & To_String (Data));
      end if;

      Memory.Set_Data
        (VSS.Stream_Element_Vectors.Conversions.Unchecked_From_Unbounded_String
           (Data));

      Look_Ahead (Seq, Request_Seq, A_Type, R_Success, Message, Event);

      Reader.Set_Stream (Memory'Unchecked_Access);
      Stream.R.Read_Next;
      pragma Assert (Stream.R.Is_Start_Document);
      Stream.R.Read_Next;

      if A_Type = "response" then
         if Request_Seq /= 0 then
            Position := Self.Sent.Find (Request_Seq);

            if Requests_Maps.Has_Element (Position) then
               Request := Requests_Maps.Element (Position);
               Self.Sent.Delete (Position);

               if Self.Status /= Terminating
                 or else Request.all in
                   DAP.Requests.Disconnect.Disconnect_DAP_Request'Class
               then
                  if R_Success.Is_Set
                    and then not R_Success.Value
                  then
                     begin
                        Request.On_Error_Message (Self'Access, Message);
                     exception
                        when E : others =>
                           Trace (Me, E);
                     end;

                  else
                     declare
                        Parsed : Boolean := True;
                     begin
                        if Request.Kernel = null
                          or else not Request.Kernel.Is_In_Destruction
                        then
                           Request.On_Result_Message
                             (Self'Access, Reader, Parsed, New_Request);

                           if not Parsed then
                              Request.On_Error_Message
                                (Self'Access, "Can't parse response");
                           end if;

                           GPS.Kernel.Hooks.Dap_Response_Processed_Hook.Run
                             (Kernel => Request.Kernel,
                              Method => Request.Method);
                        end if;

                     exception
                        when E : others =>
                           Trace (Me, E);
                     end;
                  end if;
               end if;

               DAP.Requests.Destroy (Request);
            end if;
         end if;

         if New_Request /= null then
            Self.Process (New_Request);
         end if;

      elsif A_Type = "event" then
         if Self.Status /= Terminating then
            Self.Process_Event (Reader, Event);
         end if;
      end if;

   exception
      when E : others =>
         Trace (Me, E);
   end On_Raw_Message;

   -------------------
   -- Process_Event --
   -------------------

   procedure Process_Event
     (Self   : in out DAP_Client;
      Stream : in out VSS.JSON.Pull_Readers.JSON_Pull_Reader'Class;
      Event  : VSS.Strings.Virtual_String)
   is
      use VSS.Strings;
      use DAP.Tools.Enum;
      use GNATCOLL.VFS;

      Success : Boolean := True;
   begin
      if Event = "output" then
         declare
            output          : DAP.Tools.OutputEvent;
            Output_Category : constant DAP.Tools.Enum.OutputEvent_category :=
              (if output.a_body.category.Is_Set then
                  output.a_body.category.Value
               else
                  console);
            --  According to the DAP documentation, 'console' is assumed
            --  when the output category is not specified.
         begin
            DAP.Tools.Inputs.Input_OutputEvent (Stream, output, Success);

            if not Success then
               return;
            end if;

            --  Display the received output in the debugger or the debuggee
            --  console depending on the output category.
            --  When it exists, the debugger console should output the 'stdout'
            --  and 'stderr' output channels, which correspond to the
            --  debuggee's output according to DAP documentation.

            declare
               Debuggee_Console : constant Interactive_Console :=
                 DAP.Views.Consoles.Get_Debuggee_Interactive_Console (Self);
               Debugger_Console : constant Interactive_Console :=
                 DAP.Views.Consoles.Get_Debugger_Interactive_Console (Self);
               Output_Console   : constant Interactive_Console :=
                 (if Output_Category not in stdout | stderr then
                     Debugger_Console
                  elsif Debugger_Console /= null then
                     Debuggee_Console
                  else
                     Debugger_Console);
               Mode             : constant GPS.Kernel.Message_Type :=
                 (case Output_Category is
                     when stderr =>
                       GPS.Kernel.Error,
                     when console =>
                       GPS.Kernel.Verbose,
                     when others  =>
                       GPS.Kernel.Info);
               Text             : constant String :=
                 UTF8 (output.a_body.output);
            begin
               if Output_Console /= null then
                  Output_Console.Insert
                    (Text    => Text,
                     Mode    => Mode,
                     Add_LF  => False);
               end if;
            end;
         end;

      elsif Event = "initialized" then
         Self.Set_Status (Initialized);

      elsif Event = "stopped" then
         declare
            stop : DAP.Tools.StoppedEvent;
         begin
            DAP.Tools.Inputs.Input_StoppedEvent (Stream, stop, Success);
            if not Success then
               Self.Set_Status (Stopped);
               return;
            end if;

            if stop.a_body.threadId.Is_Set then
               Integer_Sets.Include
                 (Self.Stopped_Threads, stop.a_body.threadId.Value);
               Self.Selected_Thread := stop.a_body.threadId.Value;
            end if;
            Self.All_Threads_Stopped := stop.a_body.allThreadsStopped;

            if stop.a_body.reason = breakpoint then
               declare
                  File    : GNATCOLL.VFS.Virtual_File;
                  Line    : Integer := 0;
                  Address : Address_Type;
               begin
                  Self.Breakpoints.Stopped (stop, File, Line, Address);
                  Self.Get_Stack_Trace.Set_Frame (0, File, Line, Address);
               end;

            elsif stop.a_body.reason = step
              and then stop.a_body.threadId.Is_Set
            then
               null;

            else
               Trace (Me, "Debugger" & Self.Id'Img & " stopped:" &
                        stop.a_body.reason'Img);
            end if;

            --  Get stopped frameId/file/line/address
            if Self.Selected_Thread /= 0 then
               Self.Get_Stack_Trace.Send_Request (Self'Access);

            elsif Self.Get_Stack_Trace.Get_Current_File /= No_File then
               Self.Set_Status (Stopped);
            end if;

            --  Trigger Debuggee_Started_Hook if we did not trigger it before
            if not Self.Is_Debuggee_Started_Called then
               Self.Is_Debuggee_Started_Called := True;
               GPS.Kernel.Hooks.Debuggee_Started_Hook.Run
                 (Self.Kernel, Self.Visual);
            end if;

         end;

      elsif Event = "continued" then
         declare
            Continued : DAP.Tools.ContinuedEvent;
         begin
            DAP.Tools.Inputs.Input_ContinuedEvent (Stream, Continued, Success);
            if Continued.a_body.allThreadsContinued then
               Self.All_Threads_Stopped := False;
               Integer_Sets.Clear (Self.Stopped_Threads);
            else
               Integer_Sets.Exclude
                 (Self.Stopped_Threads, Continued.a_body.threadId);
            end if;

            Self.Set_Status (Running);
         end;

      elsif Event = "breakpoint" then
         declare
            use type DAP.Modules.Breakpoint_Managers.
              DAP_Client_Breakpoint_Manager_Access;

            Event : DAP.Tools.BreakpointEvent;
         begin
            DAP.Tools.Inputs.Input_BreakpointEvent (Stream, Event, Success);
            if Success
              and then Self.Breakpoints /= null
            then
               Self.Breakpoints.On_Notification (Event.a_body);
            else
               Trace (Me, "Can't parse breakpoint notification");
            end if;
         end;

      elsif Event = "thread" then
         --  The tread view uses requests to get the list of threads.
         null;

      elsif Event = "exited" then
         --  Trigger the hook to inform that debuggee process is finished
         if Self.Is_Debuggee_Started_Called then
            Self.Is_Debuggee_Started_Called := False;
            GPS.Kernel.Hooks.Debugger_Process_Terminated_Hook.Run
              (Self.Kernel, Self.Visual);
         end if;

      elsif Event = "terminated" then
         if Self.Is_Debuggee_Started_Called then
            Self.Is_Debuggee_Started_Called := False;
            GPS.Kernel.Hooks.Debugger_Process_Terminated_Hook.Run
              (Self.Kernel, Self.Visual);
         end if;
         Self.Set_Status (Ready);
         Display_In_Debugger_Console (Self, "Terminated");

      elsif Event = "module" then
         --  Do not handle, at least for now.
         null;

      elsif Event = "process" then
         --  Do not handle, at least for now.
         null;

      else
         Self.Kernel.Get_Messages_Window.Insert_Error
           ("Event:" & UTF8 (Event));

         Trace (Me, "Event:" & UTF8 (Event));
      end if;

   exception
      when E : others =>
         Trace (Me, E);
   end Process_Event;

   --------------------------
   -- Process_User_Command --
   --------------------------

   procedure Process_User_Command
     (Self              : in out DAP_Client;
      Cmd               : String;
      Output_Command    : Boolean := False;
      Result_In_Console : Boolean := False;
      On_Result_Message : GNATCOLL.Scripts.Subprogram_Type := null;
      On_Error_Message  : GNATCOLL.Scripts.Subprogram_Type := null;
      On_Rejected       : GNATCOLL.Scripts.Subprogram_Type := null)
   is
      use GNATCOLL.Scripts;
      use GNATCOLL.VFS;

      Request : DAP.Requests.DAP_Request_Access;

      Tmp     : constant String := GPS.Kernel.Hooks.
        Debugger_Command_Action_Hook.Run
          (Kernel   => Self.Kernel,
           Debugger => Self.Get_Visual,
           Str      => Cmd);

      Result_Message : GNATCOLL.Scripts.Subprogram_Type := On_Result_Message;
      Error_Message  : GNATCOLL.Scripts.Subprogram_Type := On_Error_Message;
      Rejected       : GNATCOLL.Scripts.Subprogram_Type := On_Rejected;

      Matched       : VSS.Regular_Expressions.Regular_Expression_Match;
      Details_Match : VSS.Regular_Expressions.Regular_Expression_Match;
      VSS_Cmd       : Virtual_String;
      Details       : Virtual_String;
      Level         : Integer;

      procedure Add_BP_For_Offset;

      -----------------------
      -- Add_BP_For_Offset --
      -----------------------

      procedure Add_BP_For_Offset is
         Line : Editable_Line_Type :=
           Editable_Line_Type'Value
             (UTF8 (Details_Match.Captured (Bp_Offset_Idx)));
      begin
         if Details_Match.Captured
           (Bp_Offset_Sig_Idx) = "+"
         then
            Line := Editable_Line_Type
              (Self.Get_Stack_Trace.Get_Current_Line) + Line;
         else
            Line := Editable_Line_Type'Max
              (0, Editable_Line_Type
                 (Self.Get_Stack_Trace.Get_Current_Line) - Line);
         end if;

         Self.Break_Source
           (File      => Self.Get_Stack_Trace.Get_Current_File,
            Line      => Line,
            Temporary => Matched.Has_Capture (Bp_Temporary_Idx),
            Condition => Details_Match.Captured (Bp_Condition_Idx));
      end Add_BP_For_Offset;

   begin
      if Output_Command then
         Self.Display_In_Debugger_Console (Cmd, Is_Command => True);
      end if;

      if Tmp /= "" then
         VSS_Cmd := VSS.Strings.Conversions.To_Virtual_String (Tmp);

         if Self.Is_Quit_Command (VSS_Cmd) then
            Self.Quit;

         else
            Matched := Is_Catch_Exception_Pattern.Match (VSS_Cmd);
            if Matched.Has_Match then
               Self.Break_Exception
                 (Name      => UTF8 (Matched.Captured (2)),
                  Unhandled => False,
                  Temporary => Matched.Captured (1) = "tcatch");

               VSS_Cmd.Clear;
            end if;

            Matched := Is_Breakpoint_Pattern.Match (VSS_Cmd);
            if Matched.Has_Match then
               --  if hardware bp
               if Matched.Has_Capture (Bp_Not_Supported_Idx) then
                  Self.Display_In_Debugger_Console
                    ("Hardware breakpoints are not supported");

               elsif not Matched.Has_Capture (Bp_Details_Idx)
                 and then Self.Get_Stack_Trace.Get_Current_Address /=
                   Invalid_Address
               then
                  --  no details, bp for the next instruction
                  Self.Break_Address
                    (Address   => Add_Address
                       (Self.Get_Stack_Trace.Get_Current_Address, 1),
                     Temporary => Matched.Has_Capture (Bp_Temporary_Idx),
                     Condition => Details_Match.Captured (Bp_Condition_Idx));

               else
                  Details       := Matched.Captured (Bp_Details_Idx);
                  Details_Match :=
                    Breakpoint_Details_Pattern.Match (Details);

                  if Details_Match.Has_Match then
                     if Details_Match.Has_Capture (Bp_Offset_Idx)
                       and then Self.Get_Stack_Trace.Get_Current_File /=
                         No_File
                     then
                        Add_BP_For_Offset;

                     elsif Details_Match.Has_Capture (Bp_Address_Idx) then
                        Self.Break_Address
                          (String_To_Address
                             (UTF8 (Details_Match.Captured (Bp_Address_Idx))),
                           Matched.Has_Capture (Bp_Temporary_Idx),
                           Details_Match.Captured (Bp_Condition_Idx));

                     elsif Details_Match.Has_Capture (Bp_Line_Idx)
                       and then
                         (Self.Get_Stack_Trace.Get_Current_File /= No_File
                          or else Details_Match.Has_Capture (Bp_File_Idx))
                     then
                        if Details_Match.Has_Capture (Bp_File_Idx) then
                           --  have file:line pattern
                           Self.Break_Source
                             (File      => GPS.Kernel.Create
                                (+VSS.Strings.Conversions.To_UTF_8_String
                                     (Details_Match.Captured (Bp_File_Idx)),
                                 Self.Kernel),
                              Line      =>
                                Editable_Line_Type'Value (UTF8
                                  (Details_Match.Captured (Bp_Line_Idx))),
                              Temporary =>
                                Matched.Has_Capture (Bp_Temporary_Idx),
                              Condition =>
                                Details_Match.Captured (Bp_Condition_Idx));
                        else
                           --  have only line, set bp for the current
                           --  selected file
                           Self.Break_Source
                             (File      =>
                                Self.Get_Stack_Trace.Get_Current_File,
                              Line      =>
                                Editable_Line_Type'Value (UTF8
                                  (Details_Match.Captured (Bp_Line_Idx))),
                              Temporary =>
                                Matched.Has_Capture (Bp_Temporary_Idx),
                              Condition =>
                                Details_Match.Captured (Bp_Condition_Idx));
                        end if;

                     elsif Details_Match.Has_Capture (Bp_Subprogram_Idx) then
                        Self.Break_Subprogram
                          (Subprogram =>
                             (if Details_Match.Has_Capture (Bp_File_Idx)
                              then UTF8 (Details_Match.Captured (Bp_File_Idx))
                              & ":" & UTF8
                                (Details_Match.Captured (Bp_Subprogram_Idx))
                              else
                                 UTF8 (Details_Match.Captured
                                   (Bp_Subprogram_Idx))),
                           Temporary  =>
                             Matched.Has_Capture (Bp_Temporary_Idx),
                           Condition  =>
                             Details_Match.Captured (Bp_Condition_Idx));

                     else
                        Self.Display_In_Debugger_Console
                          ("Can't set breakpoint");
                     end if;

                  else
                     Self.Display_In_Debugger_Console
                       ("Can't parse breakpoint details");
                  end if;
               end if;

               VSS_Cmd.Clear;
            end if;

            --  Is the `continue` command
            Matched := Is_Continue_Pattern.Match (VSS_Cmd);
            if Matched.Has_Match then
               --  Send the corresponding request
               Self.Continue_Execution;
               VSS_Cmd.Clear;
            end if;

            if not VSS_Cmd.Is_Empty then
               if Self.Is_Frame_Up_Command (VSS_Cmd) then
                  Self.Get_Stack_Trace.Frame_Up (Self'Access);

               elsif Self.Is_Frame_Down_Command (VSS_Cmd) then
                  Self.Get_Stack_Trace.Frame_Down (Self'Access);

               elsif Self.Is_Frame_Command (VSS_Cmd, Level) then
                  Self.Get_Stack_Trace.Select_Frame (Level, Self'Access);
               end if;

               Request := DAP.Requests.DAP_Request_Access
                 (DAP.Clients.Evaluate.Create_Command
                    (Self,
                     VSS_Cmd,
                     Result_In_Console,
                     Result_Message, Error_Message, Rejected));

               Self.Enqueue (Request);
               return;
            end if;
         end if;
      end if;

      if Result_Message /= null then
         declare

            Arguments : Callback_Data'Class :=
              Result_Message.Get_Script.Create (1);
         begin
            Set_Nth_Arg (Arguments, 1, String'(""));

            declare
               Dummy : GNATCOLL.Any_Types.Any_Type :=
                 Result_Message.Execute (Arguments);

            begin
               null;
            end;

            Free (Arguments);
         end;

         GNATCOLL.Scripts.Free (Result_Message);
      end if;

      GNATCOLL.Scripts.Free (Error_Message);
      GNATCOLL.Scripts.Free (Rejected);

   exception
      when E : others =>
         Trace (Me, E);

         if Error_Message /= null then
            declare

               Arguments : Callback_Data'Class :=
                 Result_Message.Get_Script.Create (1);
            begin
               Set_Nth_Arg
                 (Arguments, 1, Ada.Exceptions.Exception_Information (E));

               declare
                  Dummy : GNATCOLL.Any_Types.Any_Type :=
                    Error_Message.Execute (Arguments);

               begin
                  null;
               end;

               Free (Arguments);
            end;
         end if;

         GNATCOLL.Scripts.Free (Result_Message);
         GNATCOLL.Scripts.Free (Error_Message);
         GNATCOLL.Scripts.Free (Rejected);
   end Process_User_Command;

   ---------------------------------
   -- Display_In_Debugger_Console --
   ---------------------------------

   procedure Display_In_Debugger_Console
     (Self       : in out DAP_Client;
      Msg        : String;
      Is_Command : Boolean := False)
   is
      Console : constant access Interactive_Console_Record'Class :=
        DAP.Views.Consoles.Get_Debugger_Interactive_Console (Self);
      Console_Child : MDI_Child;

   begin
      if Console /= null then
         if Is_Command then
            Console.Insert
              (Msg,
               Add_LF         => True,
               Mode      => GPS.Kernel.Verbose,
               Add_To_History => True);
         else
            Console.Insert (Msg, Add_LF => True);
         end if;

         Console_Child := Find_MDI_Child
           (Get_MDI (Self.Kernel), Self.Debugger_Console);

         if Console_Child /= null then
            Highlight_Child (Console_Child);
         end if;
      end if;
   end Display_In_Debugger_Console;

   ---------------------
   -- Get_Stack_Trace --
   ---------------------

   function Get_Stack_Trace
     (Self : DAP_Client)
      return DAP.Clients.Stack_Trace.Stack_Trace_Access is
   begin
      return DAP.Clients.Stack_Trace.Stack_Trace_Access (Self.Stack_Trace);
   end Get_Stack_Trace;

   ----------------
   -- On_Started --
   ----------------

   overriding procedure On_Started (Self : in out DAP_Client) is
      Request : DAP.Requests.DAP_Request_Access :=
        DAP.Requests.DAP_Request_Access
          (DAP.Clients.Initialize.Create (Self.Kernel));
   begin
      Self.Process (Request);
   end On_Started;

   ---------------------
   -- On_Disconnected --
   ---------------------

   procedure On_Disconnected (Self : in out DAP_Client) is
   begin
      Self.Stop;
   exception
      when E : others =>
         Trace (Me, E);
   end On_Disconnected;

   -------------
   -- Process --
   -------------

   procedure Process
     (Self    : in out DAP_Client;
      Request : in out DAP.Requests.DAP_Request_Access)
   is
      Id     : constant Integer :=
        Self.Get_Request_ID;
      Writer : VSS.JSON.Push_Writers.JSON_Simple_Push_Writer;
      Stream : aliased VSS.Text_Streams.Memory_UTF8_Output.
        Memory_UTF8_Output_Stream;

   begin
      if Self.Status /= Terminating
        or else Request.all in
          DAP.Requests.Disconnect.Disconnect_DAP_Request'Class
      then
         Request.Set_Seq (Id);
         Writer.Set_Stream (Stream'Unchecked_Access);
         Writer.Start_Document;
         Request.Write (Writer);
         Writer.End_Document;

         --  Send request's message

         Self.Send_Buffer (Stream.Buffer);

         if DAP_Log.Is_Active then
            Trace (DAP_Log,
                   "[" & Self.Id'Img & "->]"
                   & VSS.Stream_Element_Vectors.Conversions.Unchecked_To_String
                     (Stream.Buffer));
         end if;

         --  Add request to the map

         Self.Sent.Insert (Id, Request);

      else
         Request.On_Rejected (Self'Access);
         DAP.Requests.Destroy (Request);
      end if;
   end Process;

   -------------------------
   -- Reject_All_Requests --
   -------------------------

   procedure Reject_All_Requests (Self : in out DAP_Client) is
   begin
      --  Reject all queued requests. Clean commands queue.

      for Request of Self.Sent loop
         Request.On_Rejected (Self'Access);
         DAP.Requests.Destroy (Request);
      end loop;

      Self.Sent.Clear;
   end Reject_All_Requests;

   -----------
   -- Start --
   -----------

   procedure Start
     (Self            : in out DAP_Client;
      Project         : GNATCOLL.Projects.Project_Type;
      File            : GNATCOLL.VFS.Virtual_File;
      Executable_Args : String)
   is
      Node_Args : Spawn.String_Vectors.UTF_8_String_Vector;

      function Get_Debug_Adapter_Command return String;
      --  Returns name of debugger and parameters for it

      ---------------------------------
      -- Get_Debug_Adapter_Executabe --
      ---------------------------------

      function Get_Debug_Adapter_Command return String is
      begin
         if DAP.Modules.Preferences.DAP_Adapter.Get_Pref /= "" then
            return DAP.Modules.Preferences.DAP_Adapter.Get_Pref;
         end if;

         if Project.Has_Attribute
           (GNATCOLL.Projects.Debugger_Command_Attribute)
         then
            --  Return the debugger command set in the project file if any
            declare
               Debugger_Cmd : constant String := Project.Attribute_Value
                 (GNATCOLL.Projects.Debugger_Command_Attribute);
            begin
               return Debugger_Cmd;
            end;
         end if;

         --  Return the debugger command set from the toolchain
         declare
            Tc           : constant Toolchain :=
              Self.Kernel.Get_Toolchains_Manager.Get_Toolchain (Project);
            Debugger_Cmd : constant String := Get_Command
              (Tc, Toolchains.Debugger);
         begin
            return Debugger_Cmd;
         end;
      end Get_Debug_Adapter_Command;

      Debug_Adapter_Cmd : constant String := Get_Debug_Adapter_Command;

   begin

      Self.Project := Project;
      Self.Executable := File;
      Self.Executable_Args := Ada.Strings.Unbounded.To_Unbounded_String
        (Executable_Args);

      declare
         use GNATCOLL.VFS;
         Debug_Adapter_Args : GNAT.Strings.String_List_Access :=
           GNATCOLL.Utils.Split (Debug_Adapter_Cmd, On => ' ');
         Exec : constant Virtual_File :=
           Locate_On_Path (+Debug_Adapter_Args (Debug_Adapter_Args'First).all);
      begin
         --  TODO: eveything here is GDB specific, we need to find a better
         --  solution at some point.
         Trace (Me, "Launching the debug adapter: " & (+Exec.Full_Name)
                & " for file:" & (+Full_Name (Self.Executable)));
         Self.Set_Program (+Exec.Full_Name);
         Node_Args.Append ("-i=dap");

         for J in Debug_Adapter_Args'First + 1 .. Debug_Adapter_Args'Last loop
            Node_Args.Append (Debug_Adapter_Args (J).all);
         end loop;

         GNAT.Strings.Free (Debug_Adapter_Args);
      end;

      Self.Set_Arguments (Node_Args);
      Self.Start;
   end Start;

   --------------------
   -- On_Before_Exit --
   --------------------

   procedure On_Before_Exit (Self : in out DAP_Client) is
      use type DAP.Modules.Breakpoint_Managers.
        DAP_Client_Breakpoint_Manager_Access;

   begin
      if Self.Status = Initialization
        or else Self.Status = Terminating
      then
         return;
      end if;

      if Self.Breakpoints /= null then
         Self.Breakpoints.Finalize;
         Free (Self.Breakpoints);
      end if;

      Free (Self.Stack_Trace);
   exception
      when E : others =>
         Trace (Me, E);
   end On_Before_Exit;

   ----------
   -- Quit --
   ----------

   procedure Quit (Self : in out DAP_Client)
   is
      use type DAP.Modules.Breakpoint_Managers.
        DAP_Client_Breakpoint_Manager_Access;

      Disconnect : DAP.Clients.Disconnect.Disconnect_Request_Access;
      Old        : constant Debugger_Status_Kind := Self.Status;
   begin
      if Old = Terminating then
         return;
      end if;

      Self.Set_Status (Terminating);
      Self.Reject_All_Requests;

      if Old /= Initialization then
         Disconnect := DAP.Clients.Disconnect.Create
           (Kernel => Self.Kernel, Terminate_Debuggee => True);

         Self.Process (DAP.Requests.DAP_Request_Access (Disconnect));

         if Self.Breakpoints /= null then
            Self.Breakpoints.Finalize;
            Free (Self.Breakpoints);
         end if;

      else
         Self.Stop;
      end if;

   exception
      when E : others =>
         Trace (Me, E);
   end Quit;

   ----------------
   -- On_Destroy --
   ----------------

   procedure On_Destroy (Self : in out DAP_Client) is
   begin
      if Self.Status /= Terminating then
         Self.Set_Status (Terminating);
         Self.Reject_All_Requests;
         Self.Stop;
      end if;
   end On_Destroy;

   --------------
   -- Value_Of --
   --------------

   procedure Value_Of
     (Self   : in out DAP_Client;
      Entity : String;
      Label  : Gtk.Label.Gtk_Label)
   is
      Req : DAP.Requests.DAP_Request_Access := DAP.Requests.DAP_Request_Access
        (DAP.Clients.Evaluate.Create_Value_Of
           (Self, Label, VSS.Strings.Conversions.To_Virtual_String (Entity)));
   begin
      Self.Enqueue (Req);
   end Value_Of;

   ----------------------------
   -- Set_Breakpoint_Command --
   ----------------------------

   procedure Set_Breakpoint_Command
     (Self    : in out DAP_Client;
      Id      : Breakpoint_Identifier;
      Command : VSS.Strings.Virtual_String)
   is
      Req : DAP.Requests.DAP_Request_Access;
      Cmd : VSS.Strings.Virtual_String;
   begin
      Cmd := VSS.Strings.Conversions.To_Virtual_String
        ("command" & Breakpoint_Identifier'Image (Id)
         & ASCII.LF) & Command;

      if not Command.Is_Empty
        and then VSS.Strings.Cursors.Iterators.Characters.Element
          (Command.At_Last_Character) /= VSS.Characters.Latin.Line_Feed
      then
         Cmd.Append (VSS.Characters.Latin.Line_Feed);
      end if;
      Cmd.Append (VSS.Strings.Conversions.To_Virtual_String ("end"));

      Req := DAP.Requests.DAP_Request_Access
        (DAP.Clients.Evaluate.Create_Command (Self, Cmd));

      Self.Enqueue (Req);
   end Set_Breakpoint_Command;

   ------------------------
   -- Command_In_Process --
   ------------------------

   overriding function Command_In_Process
     (Visual : not null access DAP_Visual_Debugger) return Boolean is
   begin
      return Visual.Client /= null
        and then not Visual.Client.Is_Ready_For_Command;
   end Command_In_Process;

   ------------------------
   -- Continue_Execution --
   ------------------------

   procedure Continue_Execution (Self : in out DAP_Client)
   is
      Request : DAP.Requests.DAP_Request_Access;
   begin
      if Self.Get_Status = DAP.Types.Stopped then
         Request := DAP.Requests.DAP_Request_Access
           (DAP.Clients.Continue.Create
              (Self.Kernel, Self.Get_Current_Thread));
         Self.Enqueue (Request);
      end if;
   end Continue_Execution;

   ----------------------
   -- Show_Breakpoints --
   ----------------------

   procedure Show_Breakpoints (Self : DAP_Client) is
      use type DAP.Modules.Breakpoint_Managers.
        DAP_Client_Breakpoint_Manager_Access;
   begin
      if Self.Breakpoints /= null then
         Self.Breakpoints.Show_Breakpoints;
      end if;
   end Show_Breakpoints;

   --------------------------
   -- Get_Variable_Address --
   --------------------------

   procedure Get_Variable_Address
     (Self     : in out DAP_Client;
      Variable : String) is
   begin
      if Variable /= "" then
         declare
            Req : DAP.Requests.DAP_Request_Access :=
              DAP.Requests.DAP_Request_Access
                (DAP.Clients.Evaluate.Create_Variable_Address
                   (Self, Variable));
         begin
            Self.Enqueue (Req);
         end;
      end if;
   end Get_Variable_Address;

end DAP.Clients;
