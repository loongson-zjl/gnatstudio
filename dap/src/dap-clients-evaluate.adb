------------------------------------------------------------------------------
--                               GNAT Studio                                --
--                                                                          --
--                        Copyright (C) 2023, AdaCore                       --
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

with Glib.Convert;
with Glib.Object;                use Glib.Object;

with GNATCOLL.Any_Types;

with VSS.Regular_Expressions;
with VSS.Strings.Conversions;

with String_Utils;

with DAP.Clients.Stack_Trace;    use DAP.Clients.Stack_Trace;
with DAP.Views.Memory;
with DAP.Views.Registers;
with DAP.Views.Variables;
with DAP.Utils;                  use DAP.Utils;

package body DAP.Clients.Evaluate is

   Endian_Pattern : constant VSS.Regular_Expressions.
     Regular_Expression := VSS.Regular_Expressions.To_Regular_Expression
       ("little endian");
   --  Pattern used to detect endian

   ------------
   -- Create --
   ------------

   function Create
     (Client            : DAP_Client;
      Kind              : Evaluate_Kind;
      Cmd               : VSS.Strings.Virtual_String;
      Output            : Boolean := False;
      On_Result_Message : GNATCOLL.Scripts.Subprogram_Type := null;
      On_Error_Message  : GNATCOLL.Scripts.Subprogram_Type := null;
      On_Rejected       : GNATCOLL.Scripts.Subprogram_Type := null)
      return Evaluate_Request_Access
   is
      Req : constant Evaluate_Request_Access :=
        new Evaluate_Request (Client.Kernel);
   begin
      Req.Kind   := Kind;
      Req.Output := Output;

      Req.On_Result_Message := On_Result_Message;
      Req.On_Error_Message  := On_Error_Message;
      Req.On_Rejected       := On_Rejected;

      Req.Parameters.arguments.expression := Cmd;
      Req.Parameters.arguments.frameId :=
        Client.Get_Stack_Trace.Get_Current_Frame_Id;
      Req.Parameters.arguments.context :=
        (Is_Set => True, Value => DAP.Tools.Enum.repl);
      return Req;
   end Create;

   --------------------
   -- Create_Command --
   --------------------

   function Create_Command
     (Client            : DAP_Client;
      Command           : VSS.Strings.Virtual_String;
      Output            : Boolean := False;
      On_Result_Message : GNATCOLL.Scripts.Subprogram_Type := null;
      On_Error_Message  : GNATCOLL.Scripts.Subprogram_Type := null;
      On_Rejected       : GNATCOLL.Scripts.Subprogram_Type := null)
      return Evaluate_Request_Access is
   begin
      return DAP.Clients.Evaluate.Create
        (Client,
         DAP.Clients.Evaluate.Command,
         Command,
         Output,
         On_Result_Message, On_Error_Message, On_Rejected);
   end Create_Command;

   ---------------------
   -- Create_Value_Of --
   ---------------------

   function Create_Value_Of
     (Client : DAP_Client;
      Label  : Gtk.Label.Gtk_Label;
      Cmd    : VSS.Strings.Virtual_String)
      return Evaluate_Request_Access
   is
      Req : constant Evaluate_Request_Access :=
        new Evaluate_Request (Client.Kernel);
   begin
      Req.Label := Label;
      Ref (GObject (Label));
      Req.Parameters.arguments.expression := Cmd;
      Req.Parameters.arguments.frameId :=
        Client.Get_Stack_Trace.Get_Current_Frame_Id;
      Req.Parameters.arguments.context :=
        (Is_Set => True, Value => DAP.Tools.Enum.repl);
      return Req;
   end Create_Value_Of;

   -----------------------------
   -- Create_Variable_Address --
   -----------------------------

   function Create_Variable_Address
     (Client   : DAP_Client;
      Variable : String)
      return Evaluate_Request_Access is
   begin
      return DAP.Clients.Evaluate.Create
        (Client, Variable_Address,
         VSS.Strings.Conversions.
           To_Virtual_String ("print &(" & Variable & ")"));
   end Create_Variable_Address;

   --------------------
   -- Create_Set_TTY --
   --------------------

   function Create_Set_TTY
     (Client : DAP_Client;
      TTY    : String)
      return Evaluate_Request_Access is
   begin
      return Create
        (Client, Set_TTY,
         VSS.Strings.Conversions.To_Virtual_String ("tty " & TTY));
   end Create_Set_TTY;

   ------------------------
   -- Create_Show_Endian --
   ------------------------

   function Create_Show_Endian
     (Client : DAP_Client)
      return Evaluate_Request_Access is
   begin
      return DAP.Clients.Evaluate.Create
        (Client, DAP.Clients.Evaluate.Endian, "show endian");
   end Create_Show_Endian;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Self : in out Evaluate_Request) is
   begin
      GNATCOLL.Scripts.Free (Self.On_Result_Message);
      GNATCOLL.Scripts.Free (Self.On_Error_Message);
      GNATCOLL.Scripts.Free (Self.On_Rejected);

      DAP.Requests.Evaluate.Evaluate_DAP_Request (Self).Finalize;
   end Finalize;

   -----------------------
   -- On_Result_Message --
   -----------------------

   overriding procedure On_Result_Message
     (Self        : in out Evaluate_Request;
      Client      : not null access DAP.Clients.DAP_Client'Class;
      Result      : in out DAP.Tools.EvaluateResponse;
      New_Request : in out DAP.Requests.DAP_Request_Access)
   is
      use GNATCOLL.Scripts;
   begin
      New_Request := null;

      case Self.Kind is
         when Endian =>
            declare
               Match : constant VSS.Regular_Expressions.
                 Regular_Expression_Match :=
                   Endian_Pattern.Match (Result.a_body.result);
            begin
               if Match.Has_Match then
                  Client.Endian := Little_Endian;
               else
                  Client.Endian := Big_Endian;
               end if;
            end;
            Client.Set_Status (Ready);

         when Hover =>
            Self.Label.Set_Markup
              ("<b>Debugger value :</b> " & Glib.Convert.Escape_Text
                 (UTF8 (Result.a_body.result)));
            Unref (GObject (Self.Label));

         when Variable_Address =>
            declare
               S     : constant String := UTF8 (Result.a_body.result);
               Index : Integer := S'Last;
            begin
               String_Utils.Skip_To_Char (S, Index, 'x', Step => -1);
               if Index >= S'First then
                  DAP.Views.Memory.Display_Memory
                    (Self.Kernel, "0" & S (Index .. S'Last));
               else
                  DAP.Views.Memory.Display_Memory (Self.Kernel, "0");
               end if;
            end;

         when Command =>
            if Self.Output
              and then Client /= null
            then
               Client.Display_In_Debugger_Console
                 (UTF8 (Result.a_body.result), False);
            end if;

            if Self.On_Result_Message /= null then
               declare

                  Arguments : Callback_Data'Class :=
                    Self.On_Result_Message.Get_Script.Create (1);
               begin
                  Set_Nth_Arg (Arguments, 1, UTF8 (Result.a_body.result));

                  declare
                     Dummy : GNATCOLL.Any_Types.Any_Type :=
                       Self.On_Result_Message.Execute (Arguments);

                  begin
                     null;
                  end;

                  Free (Arguments);
               end;
            end if;

            --  Update views because the command may change them
            if Client /= null then
               DAP.Views.Variables.Update (Client);
               DAP.Views.Registers.Update (Client);
            end if;

         when Set_TTY =>
            null;
      end case;
   end On_Result_Message;

   -----------------
   -- On_Rejected --
   -----------------

   overriding procedure On_Rejected
     (Self   : in out Evaluate_Request;
      Client : not null access DAP.Clients.DAP_Client'Class)
   is
      use GNATCOLL.Scripts;
   begin
      case Self.Kind is
         when Hover =>
            Self.Label.Set_Markup ("<b>Debugger value :</b> (rejected)");
            Unref (GObject (Self.Label));

         when Command =>
            if Self.Output then
               Client.Display_In_Debugger_Console ("Rejected", False);
            end if;

            if Self.On_Rejected /= null then
               declare
                  Arguments : Callback_Data'Class :=
                    Self.On_Rejected.Get_Script.Create (0);
                  Dummy     : GNATCOLL.Any_Types.Any_Type :=
                    Self.On_Rejected.Execute (Arguments);

               begin
                  Free (Arguments);
               end;
            end if;

         when Endian =>
            Client.Set_Status (Ready);

         when Variable_Address | Set_TTY =>
            null;
      end case;
   end On_Rejected;

   ----------------------
   -- On_Error_Message --
   ----------------------

   overriding procedure On_Error_Message
     (Self    : in out Evaluate_Request;
      Client  : not null access DAP.Clients.DAP_Client'Class;
      Message : VSS.Strings.Virtual_String)
   is
      use GNATCOLL.Scripts;
   begin
      DAP.Requests.Evaluate.Evaluate_DAP_Request
        (Self).On_Error_Message (Client, Message);

      case Self.Kind is
         when Hover =>
            Self.Label.Set_Markup ("<b>Debugger value :</b> (error)");
            Unref (GObject (Self.Label));

         when Command =>
            if Self.Output then
               Client.Display_In_Debugger_Console (UTF8 (Message), False);
            end if;

            if Self.On_Error_Message /= null then
               declare
                  Arguments : Callback_Data'Class :=
                    Self.On_Error_Message.Get_Script.Create (1);

               begin
                  Set_Nth_Arg (Arguments, 1, UTF8 (Message));

                  declare
                     Dummy : GNATCOLL.Any_Types.Any_Type :=
                       Self.On_Error_Message.Execute (Arguments);

                  begin
                     null;
                  end;

                  Free (Arguments);
               end;
            end if;

         when Endian =>
            Client.Set_Status (Ready);

         when Variable_Address | Set_TTY =>
            null;
      end case;
   end On_Error_Message;

end DAP.Clients.Evaluate;
