#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <regex>
#include <dhooks>
#include <utilshelper>
#pragma newdecls required

#define COMMAND_SIZE 1024

// bool CBaseEntity::AcceptInput( const char *szInputName, CBaseEntity *pActivator, CBaseEntity *pCaller, variant_t Value, int outputID )
Handle g_hAcceptInput;

// ScriptVariant_t field types (from debug)
#define FIELD_FLOAT         1
#define FIELD_INTEGER       5
#define FIELD_CSTRING       30

DHookSetup g_hSetValueDtr;
DHookSetup g_hSendToServerConsoleDtr;

ConVar g_cvVerboseLog;
int g_iVerboseLog;

StringMap g_Rules;
ArrayList g_aRules;
ArrayList g_Regexes;
ArrayList g_RegexRules;

enum
{
	MODE_NONE = 0,
	MODE_ALL = 1,
	MODE_STRVALUE = 2,
	MODE_INTVALUE = 4,
	MODE_FLOATVALUE = 8,
	MODE_REGEXVALUE = 16,

	MODE_MIN = 32,
	MODE_MAX = 64,

	MODE_ALLOW = 128,
	MODE_DENY = 256, // Reverse
	MODE_CLAMP = 512,

	STATE_NONE = 0,
	STATE_ALLOW = 1,
	STATE_DENY = 2,
	STATE_CLAMPMIN = 4,
	STATE_CLAMPMAX = 8
};

public Plugin myinfo =
{
	name = "ServerCommandFilter",
	author = "BotoX, .Rushaway, koen",
	description = "Filters server commands using user-defined rules for maps (point_servercommand/VScript)",
	version = "1.2.0",
	url = "https://github.com/srcdslab/sm-plugin-ServerCommandFilter"
};

public void OnPluginStart()
{
	Handle hGameConf = LoadGameConfigFile("sdktools.games");
	if(hGameConf == INVALID_HANDLE)
	{
		SetFailState("Couldn't load sdktools game config!");
		return;
	}

	g_cvVerboseLog = CreateConVar("sm_scf_verbose", "2", "Verbosity level of logs \n0 = No logs \n1 = Denied: No rules/match \n2 = Denied: No rules/match + Clamped \n3 = Logs everything", _, true, 0.0, true, 3.0);
	HookConVarChange(g_cvVerboseLog, OnConVarChanged);

	AutoExecConfig(true);

	// Gamedata only supports CS:S for now
	EngineVersion iEngine = GetEngineVersion();
	if (iEngine == Engine_CSS)
	{
		GameData gd = new GameData("ServerCommandFilter.games");
		if (gd == null) {
			SetFailState("Gamedata file not found or failed to load!");
			return;
		}

		Generate_SetValueDetour(gd);
		Generate_SendToSvDetour(gd);
		delete gd;
	}

	int Offset = GameConfGetOffset(hGameConf, "AcceptInput");
	g_hAcceptInput = DHookCreate(Offset, HookType_Entity, ReturnType_Bool, ThisPointer_CBaseEntity, AcceptInput);
	DHookAddParam(g_hAcceptInput, HookParamType_CharPtr);
	DHookAddParam(g_hAcceptInput, HookParamType_CBaseEntity);
	DHookAddParam(g_hAcceptInput, HookParamType_CBaseEntity);
	DHookAddParam(g_hAcceptInput, HookParamType_Object, 20, DHookPass_ByVal|DHookPass_ODTOR|DHookPass_OCTOR|DHookPass_OASSIGNOP); //varaint_t is a union of 12 (float[3]) plus two int type params 12 + 8 = 20
	DHookAddParam(g_hAcceptInput, HookParamType_Int);

	CloseHandle(hGameConf);

	/* Late Load */
	int entity = INVALID_ENT_REFERENCE;
	while((entity = FindEntityByClassname(entity, "point_servercommand")) != INVALID_ENT_REFERENCE)
	{
		OnEntityCreated(entity, "point_servercommand");
	}
}

public void OnPluginEnd()
{
	if (g_hSetValueDtr != null)
	{
		DHookDisableDetour(g_hSetValueDtr, false, Detour_SetValue);
		delete g_hSetValueDtr;
	}

	if (g_hSendToServerConsoleDtr != null)
	{
		DHookDisableDetour(g_hSendToServerConsoleDtr, false, Detour_SendToServerConsole);
		delete g_hSendToServerConsoleDtr;
	}
}

void Generate_SetValueDetour(GameData gd)
{
	g_hSetValueDtr = DynamicDetour.FromConf(gd, "SetValue");
	if (g_hSetValueDtr == null) {
		LogError("Failed to setup \"SetValue\" detour!");
		return;
	}

	if (!DHookEnableDetour(g_hSetValueDtr, false, Detour_SetValue)) {
		LogError("Failed to detour \"SetValue()\" function!");
		return;
	}

	LogMessage("Successfully detoured \"SetValue()\" function!");
}

void Generate_SendToSvDetour(GameData gd)
{
	g_hSendToServerConsoleDtr = DynamicDetour.FromConf(gd, "SendToServerConsole");
	if (g_hSendToServerConsoleDtr == null)
	{
		LogError("Failed to setup \"SendToServerConsole\" detour!");
		return;
	}

	if (!DHookEnableDetour(g_hSendToServerConsoleDtr, false, Detour_SendToServerConsole))
	{
		LogError("Failed to detour \"SendToServerConsole()\" function!");
		return;
	}

	LogMessage("Successfully detoured \"SendToServerConsole()\" function!");
}

public void OnMapStart()
{
	LoadConfig();
}

public void OnConfigsExecuted()
{
	g_iVerboseLog = GetConVarInt(g_cvVerboseLog);
}

void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iVerboseLog = GetConVarInt(g_cvVerboseLog);
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if(StrEqual(classname, "point_servercommand"))
	{
		DHookEntity(g_hAcceptInput, false, entity);
	}
}

// bool CBaseEntity::AcceptInput( const char *szInputName, CBaseEntity *pActivator, CBaseEntity *pCaller, variant_t Value, int outputID )
public MRESReturn AcceptInput(int pThis, Handle hReturn, Handle hParams)
{
	char szInputName[128];
	DHookGetParamString(hParams, 1, szInputName, sizeof(szInputName));

	if(!StrEqual(szInputName, "Command", true))
		return MRES_Ignored;

	int client = 0;
	if(!DHookIsNullParam(hParams, 2))
		client = DHookGetParam(hParams, 2);

	char sCommand[COMMAND_SIZE];
	DHookGetParamObjectPtrString(hParams, 4, 0, ObjectValueType_String, sCommand, sizeof(sCommand));

	int bReplaced = 0;
	if(client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		char sName[MAX_NAME_LENGTH];
		GetClientName(client, sName, sizeof(sName));

		char sSteamId[32];
		GetClientAuthId(client, AuthId_Engine, sSteamId, sizeof(sSteamId));

		char sUserID[32];
		FormatEx(sUserID, sizeof(sUserID), "#%d", GetClientUserId(client));

		char sTeam[32];
		if(GetClientTeam(client) == CS_TEAM_CT)
			strcopy(sTeam, sizeof(sTeam), "@ct");
		else if(GetClientTeam(client) == CS_TEAM_T)
			strcopy(sTeam, sizeof(sTeam), "@t");

		bReplaced += ReplaceString(sCommand, sizeof(sCommand), "!activator.name", sName, false);
		bReplaced += ReplaceString(sCommand, sizeof(sCommand), "!activator.steamid", sSteamId, false);
		bReplaced += ReplaceString(sCommand, sizeof(sCommand), "!activator.team", sTeam, false);
		bReplaced += ReplaceString(sCommand, sizeof(sCommand), "!activator", sUserID, false);
	}

	Action iAction = ValidateCommand(sCommand, "point_servercommand");

	if(iAction == Plugin_Stop)
	{
		DHookSetReturn(hReturn, false);
		return MRES_Supercede;
	}
	else if(iAction == Plugin_Changed || bReplaced)
	{
		ServerCommand(sCommand);
		DHookSetReturn(hReturn, true);
		return MRES_Supercede;
	}

	return MRES_Ignored;
}


/**
 * Generic validation function that can be used by both AcceptInput and SetValue
 * @param sOrigCommand    The command to validate
 * @param sSource         Source identifier for logging (e.g., "point_servercommand", "SetValue")
 * @return                Plugin_Continue if allowed, Plugin_Stop if blocked, Plugin_Changed if modified
 */
Action ValidateCommand(char[] sOrigCommand, const char[] sSource)
{
	static char sCommandRight[1024];
	static char sCommandLeft[128];
	strcopy(sCommandRight, sizeof(sCommandRight), sOrigCommand);
	TrimString(sCommandRight);

	int Split = SplitString(sCommandRight, " ", sCommandLeft, sizeof(sCommandLeft));
	if(Split == -1)
	{
		strcopy(sCommandLeft, sizeof(sCommandLeft), sCommandRight);
		Split = 0;
	}
	TrimString(sCommandLeft);
	strcopy(sCommandRight, sizeof(sCommandRight), sCommandRight[Split]);

	StringToLowerCase(sCommandLeft);
	StringToLowerCase(sCommandRight);

	ArrayList RuleList;
	if(g_Rules.GetValue(sCommandLeft, RuleList))
		return MatchRuleList(RuleList, sOrigCommand, sCommandLeft, sCommandRight, sSource);

	for(int i = 0; i < g_Regexes.Length; i++)
	{
		Regex hRegex = g_Regexes.Get(i);
		if(MatchRegex(hRegex, sCommandLeft) > 0)
		{
			RuleList = g_RegexRules.Get(i);
			return MatchRuleList(RuleList, sOrigCommand, sCommandLeft, sCommandRight, sSource);
		}
	}

	LogValidationResult(sSource, sOrigCommand, "Blocked (No Rule)", 1);

	return Plugin_Stop;
}

Action MatchRuleList(ArrayList RuleList, char[] sOrigCommand, const char[] sCommandLeft, const char[] sCommandRight, const char[] sSource)
{
	for(int r = 0; r < RuleList.Length; r++)
	{
		int State = STATE_NONE;
		StringMap Rule = RuleList.Get(r);
		int Mode;
		Rule.GetValue("mode", Mode);
		bool IsNumeric = IsCharNumeric(sCommandRight[0]) || (sCommandRight[0] == '-' && IsCharNumeric(sCommandRight[1]));

		if(Mode & MODE_ALL)
			State |= STATE_ALLOW;
		else if(Mode & MODE_STRVALUE)
		{
			static char sValue[512];
			Rule.GetString("value", sValue, sizeof(sValue));
			if(strcmp(sCommandRight, sValue) == 0)
				State |= STATE_ALLOW;
		}
		else if(Mode & MODE_INTVALUE)
		{
			int WantValue;
			int IsValue;
			Rule.GetValue("value", WantValue);
			IsValue = StringToInt(sCommandRight);

			if(IsNumeric && WantValue == IsValue)
				State |= STATE_ALLOW;
		}
		else if(Mode & MODE_FLOATVALUE)
		{
			float WantValue;
			float IsValue;
			Rule.GetValue("value", WantValue);
			IsValue = StringToFloat(sCommandRight);

			if(IsNumeric && FloatCompare(IsValue, WantValue) == 0)
				State |= STATE_ALLOW;
		}
		else if(Mode & MODE_REGEXVALUE)
		{
			Regex hRegex;
			Rule.GetValue("value", hRegex);
			if(MatchRegex(hRegex, sCommandRight) > 0)
				State |= STATE_ALLOW;
		}

		float MinValue;
		float MaxValue;
		float IsValue = StringToFloat(sCommandRight);
		if(!IsNumeric && (Mode & MODE_MIN || Mode & MODE_MAX))
			continue; // Ignore non-numerical

		if(Mode & MODE_MIN)
		{
			Rule.GetValue("minvalue", MinValue);

			if(IsValue >= MinValue)
				State |= STATE_ALLOW;
			else
				State |= STATE_DENY | STATE_CLAMPMIN;
		}
		if(Mode & MODE_MAX)
		{
			Rule.GetValue("maxvalue", MaxValue);

			if(IsValue <= MaxValue)
				State |= STATE_ALLOW;
			else
				State |= STATE_DENY | STATE_CLAMPMAX;
		}

		// Reverse mode
		if(Mode & MODE_DENY && State & STATE_ALLOW && !(State & STATE_DENY))
		{
			LogValidationResult(sSource, sOrigCommand, "Blocked (Deny)", 1);
			return Plugin_Stop;
		}

		// Clamping?
		// If there is no clamp rule (State == STATE_NONE) try to clamp to "clampvalue"
		// aka. always clamp to "clampvalue" if there are no rules in clamp mode
		if(Mode & MODE_CLAMP && (State & STATE_DENY || State == STATE_NONE))
		{
			bool Clamp = false;
			float ClampValue;
			if(Rule.GetValue("clampvalue", ClampValue))
				Clamp = true;
			else if(State & STATE_CLAMPMIN)
			{
				ClampValue = MinValue;
				Clamp = true;
			}
			else if(State & STATE_CLAMPMAX)
			{
				ClampValue = MaxValue;
				Clamp = true;
			}
			if(Clamp)
			{
				LogClampedValue(sSource, sOrigCommand, IsValue, ClampValue);
				FormatEx(sOrigCommand, COMMAND_SIZE, "%s %f", sCommandLeft, ClampValue);
				return Plugin_Changed;
			}
			else // Can this even happen? Yesh, dumb user. -> "clamp" {}
			{
				LogValidationResult(sSource, sOrigCommand, "Blocked (!Clamp)", 2);
				return Plugin_Stop;
			}
		}
		else if(Mode & MODE_CLAMP && State & STATE_ALLOW)
		{
			LogValidationResult(sSource, sOrigCommand, "Allowed (Clamp)", 3);
			return Plugin_Continue;
		}

		if(Mode & MODE_ALLOW && State & STATE_ALLOW && !(State & STATE_DENY))
		{
			LogValidationResult(sSource, sOrigCommand, "Allowed (Allow)", 3);
			return Plugin_Continue;
		}
	}

	LogValidationResult(sSource, sOrigCommand, "Blocked (No Match)", 1);
	return Plugin_Stop;
}

void Cleanup()
{
	if(!g_Rules)
		return;

	for(int i = 0; i < g_aRules.Length; i++)
	{
		ArrayList RuleList = g_aRules.Get(i);
		CleanupRuleList(RuleList);
	}
	delete g_aRules;
	delete g_Rules;

	for(int i = 0; i < g_Regexes.Length; i++)
	{
		Regex hRegex = g_Regexes.Get(i);
		delete hRegex;

		ArrayList RuleList = g_RegexRules.Get(i);
		CleanupRuleList(RuleList);
	}
	delete g_Regexes;
	delete g_RegexRules;
}

void CleanupRuleList(ArrayList RuleList)
{
	for(int j = 0; j < RuleList.Length; j++)
	{
		StringMap Rule = RuleList.Get(j);

		int Mode;
		if(Rule.GetValue("mode", Mode))
		{
			if(Mode & MODE_REGEXVALUE)
			{
				Regex hRegex;
				Rule.GetValue("value", hRegex);
				delete hRegex;
			}
		}
		delete Rule;
	}
	delete RuleList;
}

void LoadConfig()
{
	if(g_Rules)
		Cleanup();

	static char sConfigFile[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sConfigFile, sizeof(sConfigFile), "configs/ServerCommandFilter.cfg");
	if(!FileExists(sConfigFile))
		SetFailState("Could not find config: \"%s\"", sConfigFile);

	KeyValues Config = new KeyValues("ServerCommandFilter");
	if(!Config.ImportFromFile(sConfigFile))
	{
		delete Config;
		SetFailState("ImportFromFile() failed!");
	}
	if(!Config.GotoFirstSubKey(false))
	{
		delete Config;
		SetFailState("GotoFirstSubKey() failed!");
	}

	g_Rules = new StringMap();
	g_aRules = new ArrayList();
	g_Regexes = new ArrayList();
	g_RegexRules = new ArrayList();

	do
	{
		static char sLeft[128];
		Config.GetSectionName(sLeft, sizeof(sLeft));
		StringToLowerCase(sLeft);
		int LeftLen = strlen(sLeft);

		ArrayList RuleList;

		if(sLeft[0] == '/' && sLeft[LeftLen - 1] == '/')
		{
			sLeft[LeftLen - 1] = 0;
			Regex hRegex = CompileRegexWithError(sLeft[1], sLeft);
			if(hRegex == INVALID_HANDLE)
			{
				continue;
			}
			else
			{
				RuleList = new ArrayList();
				g_Regexes.Push(hRegex);
				g_RegexRules.Push(RuleList);
			}
		}
		else if(!g_Rules.GetValue(sLeft, RuleList))
		{
			RuleList = new ArrayList();
			g_Rules.SetValue(sLeft, RuleList);
			g_aRules.Push(RuleList);
		}

		// Section
		if(Config.GotoFirstSubKey(false))
		{
			do
			{
				static char sSection[128];
				Config.GetSectionName(sSection, sizeof(sSection));

				int Mode = MODE_NONE;
				if(strcmp(sSection, "deny", false) == 0)
					Mode |= MODE_DENY;
				else if(strcmp(sSection, "allow", false) == 0)
					Mode |= MODE_ALLOW;
				else if(strcmp(sSection, "clamp", false) == 0)
					Mode |= MODE_CLAMP;

				// Section
				if(Config.GotoFirstSubKey(false))
				{
					StringMap Rule = new StringMap();
					int RuleMode = MODE_NONE;
					do
					{
						static char sKey[128];
						Config.GetSectionName(sKey, sizeof(sKey));

						if(strcmp(sKey, "min", false) == 0)
						{
							float Value = Config.GetFloat(NULL_STRING);
							Rule.SetValue("minvalue", Value);
							RuleMode |= MODE_MIN;
						}
						else if(strcmp(sKey, "max", false) == 0)
						{
							float Value = Config.GetFloat(NULL_STRING);
							Rule.SetValue("maxvalue", Value);
							RuleMode |= MODE_MAX;
						}
						else if(Mode & MODE_CLAMP)
						{
							float Value = Config.GetFloat(NULL_STRING);
							Rule.SetValue("clampvalue", Value);
							RuleMode |= MODE_CLAMP;
						}
						else
						{
							StringMap Rule_ = new StringMap();
							if(ParseRule(Config, sLeft, Mode, Rule_))
								RuleList.Push(Rule_);
							else
								delete Rule_;
						}
					} while(Config.GotoNextKey(false));
					Config.GoBack();

					if(RuleMode != MODE_NONE)
					{
						Rule.SetValue("mode", Mode | RuleMode);
						RuleList.Push(Rule);
					}
					else
						delete Rule;
				}
				else // Value
				{
					StringMap Rule = new StringMap();

					if(ParseRule(Config, sLeft, Mode, Rule))
						RuleList.Push(Rule);
					else
						delete Rule;
				}

			} while(Config.GotoNextKey(false));
			Config.GoBack();
		}
		else // Value
		{
			StringMap Rule = new StringMap();

			if(ParseRule(Config, sLeft, MODE_ALLOW, Rule))
				RuleList.Push(Rule);
			else
				delete Rule;
		}
	} while(Config.GotoNextKey(false));
	delete Config;

	for(int i = 0; i < g_aRules.Length; i++)
	{
		ArrayList RuleList = g_aRules.Get(i);
		SortADTArrayCustom(RuleList, SortRuleList);
	}
}

bool ParseRule(KeyValues Config, const char[] sLeft, int Mode, StringMap Rule)
{
	static char sValue[512];
	if(Config.GetDataType(NULL_STRING) == KvData_String)
	{
		Config.GetString(NULL_STRING, sValue, sizeof(sValue));

		int ValueLen = strlen(sValue);
		if(sValue[0] == '/' && sValue[ValueLen - 1] == '/')
		{
			sValue[ValueLen - 1] = 0;
			Regex hRegex = CompileRegexWithError(sValue[1], sLeft);
			if(hRegex == INVALID_HANDLE)
			{
				return false;
			}
			else
			{
				Rule.SetValue("mode", Mode | MODE_REGEXVALUE);
				Rule.SetValue("value", hRegex);
			}
		}
		else
		{
			StringToLowerCase(sValue);
			Rule.SetValue("mode", Mode | MODE_STRVALUE);
			Rule.SetString("value", sValue);
		}
	}
	else if(Config.GetDataType(NULL_STRING) == KvData_Int)
	{
		int Value = Config.GetNum(NULL_STRING);
		Rule.SetValue("mode", Mode | MODE_INTVALUE);
		Rule.SetValue("value", Value);
	}
	else if(Config.GetDataType(NULL_STRING) == KvData_Float)
	{
		float Value = Config.GetFloat(NULL_STRING);
		Rule.SetValue("mode", Mode | MODE_FLOATVALUE);
		Rule.SetValue("value", Value);
	}
	else
		Rule.SetValue("mode", Mode | MODE_ALL);

	return true;
}

public int SortRuleList(int index1, int index2, Handle array, Handle hndl)
{
	StringMap Rule1 = GetArrayCell(array, index1);
	StringMap Rule2 = GetArrayCell(array, index2);

	int Mode1;
	int Mode2;
	Rule1.GetValue("mode", Mode1);
	Rule2.GetValue("mode", Mode2);

	// Deny should be first
	if(Mode1 & MODE_DENY && !(Mode2 & MODE_DENY))
		return -1;
	if(Mode2 & MODE_DENY && !(Mode1 & MODE_DENY))
		return 1;

	// Clamp should be last
	if(Mode1 & MODE_CLAMP && !(Mode2 & MODE_CLAMP))
		return 1;
	if(Mode2 & MODE_CLAMP && !(Mode1 & MODE_CLAMP))
		return -1;

	return 0;
}

/**
* Generic action handler for validation results
* @param iAction    Action returned by ValidateCommand
* @param sCommand   The command to execute if changed
* @return           MRES_Supercede to block, MRES_Ignored to continue
*/
MRESReturn HandleValidationAction(Action iAction, const char[] sCommand)
{
	if (iAction == Plugin_Stop)
	{
		return MRES_Supercede;
	}
	else if(iAction == Plugin_Changed)
	{
		// To avoid memory manipulation, better execute the command clamped
		ServerCommand(sCommand);
		return MRES_Supercede;
	}

	return MRES_Ignored;
}

/**
* Detour callback for CScriptConvarAccessor::SetValue
* From https://developer.valvesoftware.com/wiki/Team_Fortress_2/Scripting/Script_Functions
* 
* Original C++ signature:
* void CScriptConvarAccessor::SetValue(const char *cvar, ScriptVariant_t value)
* 
* Compiled signature (with implicit 'this' pointer):
* CScriptConvarAccessor::SetValue(this*, const char*, ScriptVariant_t)
* 
* @param hParams   DHooks parameter handle
* @return          MRES_Handled to block original execution, MRES_Ignored to continue
*/
public MRESReturn Detour_SetValue(DHookParam hParams)
{
	char szCvar[128];
	hParams.GetString(1, szCvar, sizeof(szCvar));

	Address pVariant = hParams.GetAddress(2);
	if (pVariant == Address_Null)
		return MRES_Ignored;

	int iType = LoadFromAddress(pVariant + view_as<Address>(8), NumberType_Int16);
	int iRawValue = LoadFromAddress(pVariant, NumberType_Int32);

	char sCommand[COMMAND_SIZE];
	switch(iType)
	{
		case FIELD_INTEGER:
		{
			FormatEx(sCommand, sizeof(sCommand), "%s %d", szCvar, iRawValue);
		}
		case FIELD_FLOAT:
		{
			float fValue = view_as<float>(iRawValue);
			FormatEx(sCommand, sizeof(sCommand), "%s %f", szCvar, fValue);
		}
		case FIELD_CSTRING:
		{
			if (iRawValue == 0)
				return MRES_Ignored; // Null string

			char szStringValue[256];
			Address pString = view_as<Address>(iRawValue);

			bool bSuccess = false;
			for (int i = 0; i < sizeof(szStringValue) - 1; i++)
			{
				int iByte = LoadFromAddress(pString + view_as<Address>(i), NumberType_Int8);
				if (iByte == 0)
				{
					szStringValue[i] = '\0';
					bSuccess = true;
					break;
				}
				if (iByte < 32 || iByte > 126)
				{
					szStringValue[i] = '\0';
					break;
				}
				szStringValue[i] = iByte;
			}
			szStringValue[sizeof(szStringValue) - 1] = '\0';

			if (!bSuccess || strlen(szStringValue) == 0)
			{
				return MRES_Ignored; // Invalid string
			}

			FormatEx(sCommand, sizeof(sCommand), "%s %s", szCvar, szStringValue);
		}
		default:
		{
			return MRES_Ignored; // Unknown type
		}
	}

	// Validate the command using the same system as AcceptInput
	Action iAction = ValidateCommand(sCommand, "SetValue");

	return HandleValidationAction(iAction, sCommand);
}

/**
* Detour callback for SendToServerConsole
* 
* Original C++ signature:
* static void SendToServerConsole(const char *pszCommand)
* 
* This function is called when VScript executes SendToConsole() to run server commands
* 
* @param hParams   DHooks parameter handle
* @return          MRES_Ignored to allow command execution, MRES_Supercede to block
*/
public MRESReturn Detour_SendToServerConsole(DHookParam hParams)
{
	char szCommand[512];
	hParams.GetString(1, szCommand, sizeof(szCommand));
	StringToLowerCase(szCommand);

	Action iAction = ValidateCommand(szCommand, "SendToServerConsole");

	return HandleValidationAction(iAction, szCommand);
}

stock void LogValidationResult(const char[] sSource, const char[] sCommand, const char[] sReason, int minLevel = 1)
{
	if (g_iVerboseLog >= minLevel)
		LogMessage("[%s] %s: \"%s\"", sSource, sReason, sCommand);
}

stock void LogClampedValue(const char[] sSource, const char[] sCommand, float oldValue, float newValue)
{
	if (g_iVerboseLog >= 3)
		LogMessage("[%s] Clamped (%f -> %f): \"%s\"", sSource, oldValue, newValue, sCommand);
}

Regex CompileRegexWithError(const char[] pattern, const char[] context)
{
	Regex hRegex;
	static char sError[512];
	hRegex = CompileRegex(pattern, PCRE_CASELESS, sError, sizeof(sError));
	if(hRegex == INVALID_HANDLE)
	{
		LogError("Regex error in %s from %s", context, pattern);
		LogError(sError);
	}
	return hRegex;
}
