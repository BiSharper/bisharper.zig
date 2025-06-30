class CfgPatches
{
    class ADD_MISSION_SCRIPT
    {
        units[]={};
        weapons[]={};
        requiredVersion=0.1;
        requiredAddons[]=
        {
            "JM_CF_Scripts",
            "DZ_Data"
        };
    };
};

class CfgMods
{
    class JM_CommunityFramework
    {
        class defs
        {
            class missionScriptModule
            {
                files[] += { "test/path/5_Mission/" };
            };
        };
    };
};