# Load SMO extension
[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.Smo") | Out-Null;
$Date = Get-Date -Format ddMMyyyy_HHmmss

# Server List Details

Import-Module sqlps -DisableNameChecking

$CentralDBAServer = ''
$CentralDatabaseName = 'DBADatabase'
$DBADatabase = 'DBADatabase'
$LogFile= "\LogFile\DBADatabase_Last_Used_Update_" + $Date +  ".log"


<#
.Synopsis
   Write-Log writes a message to a specified log file with the current time stamp.
.DESCRIPTION
   The Write-Log function is designed to add logging capability to other scripts.
   In addition to writing output and/or verbose you can write to a log file for
   later debugging.

   By default the function will create the path and file if it does not 
   exist. 
.NOTES
   Created by: Jason Wasser @wasserja
   Modified: 4/3/2015 10:29:58 AM 

   Changelog:
    * Renamed LogPath parameter to Path to keep it standard - thanks to @JeffHicks
    * Revised the Force switch to work as it should - thanks to @JeffHicks

   To Do:
    * Add error handling if trying to create a log file in a inaccessible location.
    * Add ability to write $Message to $Verbose or $Error pipelines to eliminate
      duplicates.

.EXAMPLE
   Write-Log -Message "Log message" 
   Writes the message to c:\Logs\PowerShellLog.log
.EXAMPLE
   Write-Log -Message "Restarting Server" -Path c:\Logs\Scriptoutput.log
   Writes the content to the specified log file and creates the path and file specified. 
.EXAMPLE
   Write-Log -Message "Does not exist" -Path c:\Logs\Script.log -Level Error
   Writes the message to the specified log file as an error message, and writes the message to the error pipeline.
#>
function Write-Log
{
    [CmdletBinding()]
    ##[Alias('wl')]
    [OutputType([int])]
    Param
    (
        ## The string to be written to the log.
        [Parameter(Mandatory=$true,
                   ValueFromPipelineByPropertyName=$true,
                   Position=0)]
        [ValidateNotNullOrEmpty()]
        [Alias("LogContent")]
        [string]$Message,

        ## The path to the log file.
        [Parameter(Mandatory=$false,
                   ValueFromPipelineByPropertyName=$true,
                   Position=1)]
        [Alias('LogPath')]
        [string]$Path="C:\Logs\PowerShellLog.log",

        [Parameter(Mandatory=$false,
                    ValueFromPipelineByPropertyName=$true,
                    Position=3)]
        [ValidateSet("Error","Warn","Info")]
        [string]$Level="Info",

        [Parameter(Mandatory=$false)]
        [switch]$NoClobber
    )

    Begin
    {
    }
    Process
    {
        
        if ((Test-Path $Path) -AND $NoClobber) {
            Write-Warning 'Log file $Path already exists, and you specified NoClobber. Either delete the file or specify a different name.'
            Return
            }

        ## If attempting to write to a log file in a folder/path that doesn't exist
        ## to create the file include path.
        elseif (!(Test-Path $Path)) {
            Write-Verbose "Creating $Path."
            $NewLogFile = New-Item $Path -Force -ItemType File
            }

        else {
            ## Nothing to see here yet.
            }

        ## Now do the logging and additional output based on $Level
        switch ($Level) {
            'Error' {
                Write-Error $Message
                Write-Output "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss") ERROR: $Message" | Out-File -FilePath $Path -Append
                }
            'Warn' {
                Write-Warning $Message
                Write-Output "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss") WARNING: $Message" | Out-File -FilePath $Path -Append
                }
            'Info' {
                Write-Verbose $Message
                Write-Output "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss") INFO: $Message" | Out-File -FilePath $Path -Append
                }
            }
    }
    End
    {
    }
}

function Catch-Block
{
param ([string]$Additional)
$ErrorMessage = " On $Connection or $ServerName " + $Additional + $_.Exception.Message + $_.Exception.InnerException.InnerException.message
$Message = " This message came from the Automated Powershell script updating the DBA Database with Agent Job Information"
$Msg = $Additional + $ErrorMessage + " " + $Message
Write-Log -Path $LogFile -Message $ErrorMessage -Level Error
##  Write-EventLog -LogName Application -Source "SQLAUTOSCRIPT" -EventId 1 -EntryType Error -Message $Msg
}

## Create Log File

try{
New-Item -Path $LogFile -ItemType File
$Msg = "New File Created"
Write-Log -Path $LogFile -Message $Msg
}
catch
{
$ErrorMessage = $_.Exception.Message
$FailedItem = $_.Exception.ItemName
$Message = " This message came from the Automated Powershell script updating the DBA Database with SQL Information"

$Msg = $ErrorMessage + " " + $FailedItem + " " + $Message
## Write-EventLog -LogName Application -Source "SQLAUTOSCRIPT" -EventId 1 -EntryType Error -Message $Msg
}


Write-Log -Path $LogFile -Message "Script Started"

 $Query = @"
 SELECT [ServerName]
      ,[InstanceName]
      ,[Port]
  FROM [DBADatabase].[dbo].[InstanceList]
  Where Inactive = 0 
  AND NotContactable = 0
"@

try{
$AlltheServers= Invoke-Sqlcmd -ServerInstance $CentralDBAServer -Database $CentralDatabaseName -Query $query
$ServerNames = $AlltheServers| Select ServerName,InstanceName,Port
Write-Log -Path $LogFile -Message "Collected ServerNames from DBA Database"
}
catch
{
Catch-Block " Failed to gather Server and Instance names from the DBA Database"
}

foreach ($ServerName in $ServerNames)
{
 $InstanceName =  $ServerName|Select InstanceName -ExpandProperty InstanceName
 $Port = $ServerName| Select Port -ExpandProperty Port
$ServerName = $ServerName|Select ServerName -ExpandProperty ServerName 
 $Connection = $ServerName + '\' + $InstanceName + ',' + $Port
Write-Log -Path $LogFile -Message "Gathering Information from $Connection"
 try
 {
 $srv = New-Object ('Microsoft.SqlServer.Management.Smo.Server') $Connection
 }
catch
{
Catch-Block " Failed to connect to $Connection"
continue
}
 if (!( $srv.version)){
 Catch-Block " Failed to Connect to $Connection"
 continue
 }
  if ( $srv.version.major -eq 8){
 Catch-Block " Unable to check SQL 2000 server $Connection"
 continue
 }

 $LastReboot = $srv.databases['tempdb'].CreateDate
# Set SQL Query
$query = "WITH agg AS
(
  SELECT 
       max(last_user_seek) last_user_seek,
       max(last_user_scan) last_user_scan,
       max(last_user_lookup) last_user_lookup,
       max(last_user_update) last_user_update,
       sd.name dbname
   FROM
       sys.dm_db_index_usage_stats, master..sysdatabases sd
   WHERE
     database_id = sd.dbid AND database_id > 4
	  group by sd.name 
)
SELECT 
   dbname,
   last_read = MAX(last_read),
   last_write = MAX(last_write)
FROM
(
   SELECT dbname, last_user_seek, NULL FROM agg
   UNION ALL
   SELECT dbname, last_user_scan, NULL FROM agg
   UNION ALL
   SELECT dbname, last_user_lookup, NULL FROM agg
   UNION ALL
   SELECT dbname, NULL, last_user_update FROM agg
) AS x (dbname, last_read, last_write)
GROUP BY
   dbname
ORDER BY 1;
"

#Run Query against SQL Server
try{
$Results = Invoke-Sqlcmd -ServerInstance $ServerName -Query $query -Database master
}
catch{
Catch-Block " Failed to gather details from $Connection"
}
$Count = $Results.Count
Write-Log -Path $LogFile -Message "The Results count is $count"

foreach($result in $results)
{
# Check if value is NULL
$DBNull = [System.DBNull]::Value 
$LastRead = $Result.last_read
$LastWrite = $Result.last_write
$DBName = $Result.dbname
if(!($DBName))
{
Write-Log -Path $LogFile -Message "No Databases avaiable to query on $ServerName Database updated for $Connection"
continue
}
$Query = @"
INSERT INTO [Info].[DatabaseLastUsed]
           ([DatabaseID]
           ,[ScriptRunTime]
           ,[RebootTime]
           ,[LasRead]
           ,[LastWrite])
     VALUES
           ((SELECT DatabaseID FROM info.Databases WHERE Name = '$DBName' AND InstanceID = (SELECT INstanceID FROM dbo.InstanceList WHERE ServerName = '$ServerName'))
           ,GetDAte()
           ,'$LastReboot'
           ,'$Lastread'
           ,'$lastwrite')
"@
try{
Invoke-Sqlcmd -ServerInstance $CentralDBAServer -Database $CentralDatabaseName -Query $query -ErrorAction Stop
}
catch
{Catch-Block "Failed to add info to DBA Database"
Write-Log -Path $LogFile -Message "Query -- $Query"}
}
Write-Log -Path $LogFile -Message "DBA Database updated for $Connection"
}
Write-Log -Path $LogFile -Message "Script Finished"
