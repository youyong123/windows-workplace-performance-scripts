# v1.0, IJ, 21/7/2014
# v1.1, IJ, 11/8/2014 - Fix for Win2k3
# v1.2, IJ, 11/8/2014 - bug around defaulting port to 443 if not specified
# v1.3, IJ, 4/9/2014 - add option to dump certs
# v1.4, IJ, 20/11/2014 - cache self to C:\Windows not C:\Windows\System32 to work around 32/64-bit architecture differences.
# v1.5, IJ, 10/10/2016 - check for SHA1, RC4, 3DES, SSL3, TLS 1.0, TSL 1.1
# v1.6, RC, 12/10/2016 - Refactored


Set-StrictMode -Version 2.0

<#
param
(
	[Parameter(Position=0, Mandatory=$false, HelpMessage='Computer or domain name')] [Alias('Domain')] [string]$ComputerName = [System.Environment]::MachineName,
	[Parameter(Position=1, Mandatory=$false, HelpMessage='TCP port')] [int]$port = 443,
	[Parameter(Position=2, Mandatory=$false, HelpMessage='Expiry warning period in days')] [int]$WarningPeriod = 30,
	[Parameter(Position=3, Mandatory=$false, HelpMessage='Filename of .csv containing URLs to check')] [Alias('Path')] [string]$Filename = '',
	[Parameter(Position=4, Mandatory=$false, HelpMessage='Proxy server')] [string]$proxy = '',
	[Parameter(Position=5, Mandatory=$false, HelpMessage='Install self-assessment scheduled task')] [switch]$Install = $false,
	[Parameter(Position=6, Mandatory=$false, HelpMessage='Save certificates files to this path')] [string]$backupPath = ''
)
#>

# http://msdn.microsoft.com/en-us/library/windows/desktop/aa384076(v=vs.85).aspx



<#
	.SYNOPSIS 
	Checks local or remote SSL/TLS certificates for expiry, or use of legacy ciphers (RC4), hashes (MD5, SHA1) or protocols (SSL3, TLS 1.0, TLS 1.1)

	.DESCRIPTION
	Enumerates all TCP listening ports looking for endpoints that talk SSL/TLS, and checks the cert bound to each one.
	Takes a list of URLs and enumerates the associates VIP's for certificate compliance.
	Note: No proxy server support in v1.0

	.INPUTS
	-ComputerName <[System.String]> Dns name of remote host or VIP.  If not supplied, then will enumerate all listening ports of the local host.
	
	-Port <[Int]> - TCP/IP port number (default=443)	

	-WarningPeriod <[Int]> - How near to expiry in days before alerting 

	-Filename <[String]> - List of remote hosts/URLs to scan.  Must be a CSV file with headings: Address	Proxy	Comment

	-Install <[Switch]> - Create a scheduled task to run a weekly self-assessment on Windows server
	
	-BackupPath <[String]> - Optional path to save certificates to

    # Use the Get-SslInfo() function in preference - this one one is only for situations in which we need a proxy to connect to the host

	.OUTPUTS
	Object.
		$true or $false

	.EXAMPLE
	PS C:\> Test-SSLCertificate
		Connecting to LocalHost:80
		LocalHost:80 is not configured to use SSL/TLS
		Connecting to LocalHost:371
		LocalHost:371 is not configured to use SSL/TLS
		Connecting to LocalHost:443
		TLS connection established to LocalHost:443
		Certificate 38CD745E3A0738BC22DF4E8999176842405EB2F6 on LocalHost expires in 263 day(s) and is OK
		Connecting to LocalHost:5357
		LocalHost:5357 is not configured to use SSL/TLS

	.EXAMPLE
	PS C:\> Test-SSLCertificate -filename ListOfURLs.csv
 
	.EXAMPLE
	PS C:\> Test-SSLCertificate -domain 'wsus.btfin.com'
		Connecting to wsus.btfin.com:443
		TLS connection established to wsus.btfin.com:443
		Certificate CN=AUPOZA400.btfin.com (86B8E1939B22DEB586FB1BAD7B8DD7EE86E9E2CC) at wsus.btfin.com:443 expires in 227 day(s) and is therefore OK

	.LINK

	
#>
function Get-SslInfoViaProxy
{
    [Cmdletbinding()]
	param(
		[Parameter(Position=0, Mandatory=$true, HelpMessage="URL")] [string]$URL = 'https://LocalHost:443',
		[Parameter(Position=1, Mandatory=$false, HelpMessage="Proxy server")] [string]$proxy = ''
	)
	

	# To get more TLS session info from the proxy, we'd have to manually craft the HTTP request to the proxy, which in turn requires that an NTLM or Kerberos authentication package is created per http://www.dotnetframework.org/default.aspx/Net/Net/3@5@50727@3053/DEVDIV/depot/DevDiv/releases/whidbey/netfxsp/ndp/fx/src/Net/System/Net/_NtlmClient@cs/2/_NtlmClient@cshttp://www.dotnetframework.org/default.aspx/Net/Net/3@5@50727@3053/DEVDIV/depot/DevDiv/releases/whidbey/netfxsp/ndp/fx/src/Net/System/Net/_NtlmClient@cs/2/_NtlmClient@cs or  http://www.dotnetframework.org/default.aspx/4@0/4@0/DEVDIV_TFS/Dev10/Releases/RTMRel/ndp/fx/src/Net/System/Net/_NTAuthentication@cs/1407647/_NTAuthentication@cs	
	$result = New-Object -TypeName PSObject
	Add-Member -InputObject $result -MemberType NoteProperty -Name 'Domain' -Value $computerName
	Add-Member -InputObject $result -MemberType NoteProperty -Name 'Port' -Value $port

	[System.Security.Cryptography.X509Certificates.X509Certificate2]$cert = $null
	[System.Net.Cache.RequestCachePolicy]$cachePolicy = New-Object System.Net.Cache.RequestCachePolicy( [System.Net.Cache.RequestCacheLevel]::BypassCache)
	
	Write-Host "Connecting to $url"
	
	[System.Net.HttpWebRequest]$req = [System.Net.WebRequest]::Create( $url )
	$req.Method = "GET"
	$req.Timeout = 50000
	$req.AllowAutoRedirect = $false
	$req.MaximumAutomaticRedirections = 1
	$req.KeepAlive = $false
	#$req.Accept = "text/html, application/xhtml+xml, */*"
	$req.Headers.Add("Accept-Language", "en-AU")
	$req.UserAgent = "Cert checker"
	$req.UseDefaultCredentials = $true	
	#$req.Credentials = New-Object System.Net.NetworkCredential('anonymous', 'helloworld' )
	$req.CachePolicy = $cachePolicy
	if ($proxy.length -eq 0)
	{
		$req.proxy = $null
	} else {
		$req.proxy = New-Object System.Net.WebProxy("http://$proxy/", $true)
		$req.Proxy.UseDefaultCredentials  = $true
	}
	
	# Accept dodgy certs so that we can inspect them
	[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
	
		
	try
	{
		
		Write-Host "Connecting to $url"
	
		[Net.HttpWebResponse] $response = $req.GetResponse()
		[IO.Stream] $stream = $response.GetResponseStream()
		[IO.StreamReader] $reader = New-Object IO.StreamReader($stream)
		[string] $output = $reader.readToEnd()
		$stream.Flush()
		$stream.Close()
	
		Write-Verbose $output
		
		# Grab the server certificate
		$cert = new-Object System.Security.Cryptography.X509Certificates.X509Certificate2( $req.ServicePoint.Certificate )

		Add-Member -InputObject $result -MemberType NoteProperty -Name 'Certificate' -Value $cert
		Add-Member -InputObject $result -MemberType NoteProperty -Name 'Status' -Value 'Encrypted'
		
	}
	catch [System.Management.Automation.MethodInvocationException]
	{
		Write-Warning $_
		#switch ($_.Exception.InnerException.Response.StatusCode)
		#{
		#	'Unauthorised' { Write-Warning 'Access denied' }
		#	'Not Found' { Write-Warning 'Not Found' }
		#	default { Write-Warning $_
		#}
		# Site is not secured by TLS?
		$cert = new-Object System.Security.Cryptography.X509Certificates.X509Certificate2( $req.ServicePoint.Certificate )
		
		Add-Member -InputObject $result -MemberType NoteProperty -Name 'Certificate' -Value $cert
		Add-Member -InputObject $result -MemberType NoteProperty -Name 'Status' -Value 'Encrypted'
		
	}
	catch
	{
		Add-Member -InputObject $result -MemberType NoteProperty -Name 'Certificate' -Value $null
		Add-Member -InputObject $result -MemberType NoteProperty -Name 'Status' -Value 'Unencrypted'
		Write-Warning $_	
	}
	
	Add-Member -InputObject $result -MemberType NoteProperty -Name 'Cipher' -Value ''
	Add-Member -InputObject $result -MemberType NoteProperty -Name 'Protocol' -Value ''

	return $result
}

<#
	.SYNOPSIS 
	Tries to establish a TLS/SSL connection to the supplied endpoint, and return the server certificate

	.DESCRIPTION
	Initiate a TLS session, and grab the server certificate provided as part of the negotiation
    Use this function when a direct connection to a host is possible without a proxy server

#>
function Get-SslInfo
{

	param(
		[Parameter(Position=0, Mandatory=$false, HelpMessage="Computer or domain name")] [Alias('Domain')] [string]$ComputerName = 'LocalHost',
		[Parameter(Position=1, Mandatory=$false, HelpMessage="TCP port")] [int]$port = 443
)

    #Results Powershell Object
	$result = New-Object -TypeName PSObject
	Add-Member -InputObject $result -MemberType NoteProperty -Name 'Domain' -Value $computerName
	Add-Member -InputObject $result -MemberType NoteProperty -Name 'Port' -Value $port

    #
	[System.Security.Cryptography.X509Certificates.X509Certificate2]$cert = $null
	[System.Net.Sockets.TcpClient]$client = New-Object System.Net.Sockets.TcpClient
	[System.Net.Security.SslStream]$ssl = $null

    try
    {

		Write-Host ("Connecting to {0}:{1}" -f $ComputerName, $port)

		$client.ReceiveTimeout = 1000
	    $client.Connect($ComputerName, $port)
		
		if ($client.Connected)
		{
			
			Write-Verbose ("TCP connection established to {0}:{1}" -f $ComputerName, $port)
						
			# Note that the {$true} function will allow ANY cert to be accepted, so that we can download and inspect it
		    [Net.Security.SslStream]$ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, {$true})
			# Accept dodgy certs
			[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
			
			# Start SSL/TLS connection
			$ssl.AuthenticateAsClient( $ComputerName )

			# Was the TLS tunnel established successfully?
			if (($ssl.IsEncrypted) -and ($ssl.RemoteCertificate -ne $null))
			{

				Write-Host ("{0} connection established to {1}:{2}" -f $ssl.SslProtocol, $ComputerName, $port) -ForegroundColor Yellow   
				
				# Get the negotiated certificate
				$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
				Add-Member -InputObject $result -MemberType NoteProperty -Name 'Certificate' -Value $cert 
				Add-Member -InputObject $result -MemberType NoteProperty -Name 'Status' -Value 'Encrypted'


				# SSL3 or TLS? 
				$dodgyProtocol = $false
				
				switch ($ssl.sslProtocol)
				{
					# https://msdn.microsoft.com/en-us/library/system.security.authentication.sslprotocols(v=vs.110).aspx
					'Tls'
					{ 
						$protocolAlias = 'TLS 1.0'
						$dodgyProtocol = $true
					}
					'Tls11'
					{ 
						$protocolAlias = 'TLS 1.1'
						$dodgyProtocol = $true
					}
					'Tls12'
					{ 
						$protocolAlias = 'TLS 1.2'
						$dodgyProtocol = $false
					}
					'Tls13'	# Coming soon
					{ 
						$protocolAlias = 'TLS 1.3'
						$dodgyProtocol = $false
					}
					'Ssl2'
					{ 
						$protocolAlias = 'SSL 2.0'
						$dodgyProtocol = $true
					}
					'Ssl3'
					{ 
						$protocolAlias = 'SSL 3.0'
						$dodgyProtocol = $true
					}
					'None'
					{ 
						$protocolAlias = 'NULL'
						$dodgyProtocol = $true
					}
					default 
					{
						# $protocolAlias = $ssl.SslProtocol
						throw New-Object System.NotSupportedException( $ssl.SslProtocol )
					}
				}


				Add-Member -InputObject $result -MemberType NoteProperty -Name 'Cipher' -Value $ssl.CipherAlgorithm.ToString()
				Add-Member -InputObject $result -MemberType NoteProperty -Name 'Protocol' -Value $protocolAlias

				if ($dodgyProtocol)
				{
					$result.Status = 'Weak protocol'
					Write-EventLog -Source $EventLogSource -LogName 'Application' -EventId 10 -EntryType Warning -Message ("{0}:{1} is using the insecure {2} SSL/TLS protocol" -f $ComputerName, $port, $protocolAlias ) -ErrorAction SilentlyContinue
					Write-Warning ("{0}:{1} is using the insecure {2} SSL/TLS protocol" -f $ComputerName, $port, $protocolAlias )
				} else {
					Write-Host ("The protocol is {0}" -f $protocolAlias )
				}
				
				
				# Let's take a look at the symmetric cipher while we're here
				$badCiphers = @('Rc2', 'Rc4', 'Null', 'None', 'Des', 'TripleDes')
				if ($badCiphers -contains $ssl.CipherAlgorithm.ToString())
				{
					$result.Status = 'Weak cipher'
					Write-EventLog -Source $EventLogSource -LogName 'Application' -EventId 10 -EntryType Warning -Message ("{0}:{1} is using the insecure {2} symmetric cipher" -f $ComputerName, $port, $ssl.CipherAlgorithm ) -ErrorAction SilentlyContinue
					Write-Warning ("{0}:{1} is using the insecure {2} symmetric cipher" -f $ComputerName, $port, $ssl.CipherAlgorithm )
				} else {
					Write-Host ("{0}:{1} is using the {2} cipher algorithm" -f $ComputerName, $port, $ssl.CipherAlgorithm )
				}
			
			} else {
			
				# Hitting this line means that NULL encryption is being used with SSL
				Add-Member -InputObject $result -MemberType NoteProperty -Name 'Certificate' -Value $null
				Add-Member -InputObject $result -MemberType NoteProperty -Name 'Status' -Value 'Unencrypted'
				Write-EventLog -Source $EventLogSource -LogName 'Application' -EventId 9 -EntryType Error -Message ("{0}:{1} is using NULL encryption" -f $ComputerName, $port) -ErrorAction SilentlyContinue
				Write-Warning ("{0}:{1} is using NULL encryption" -f $ComputerName, $port)
				
			}
		}

    }
    catch [System.Security.Authentication.AuthenticationException]
    {
		Add-Member -InputObject $result -MemberType NoteProperty -Name 'Certificate' -Value $null
		Add-Member -InputObject $result -MemberType NoteProperty -Name 'Status' -Value 'Not RFC 5746 compliant'
		Write-EventLog -Source $EventLogSource -LogName 'Application' -EventId 8 -EntryType Error -Message ("{0}:{1} TLS connection failed, probably because the server is not RFC 5746 compliant: {2}" -f $ComputerName, $Port, $_.Exception.InnerException.Message) -ErrorAction SilentlyContinue
		Write-Warning ("{0}:{1} TLS connection failed, probably because the server is not RFC 5746 compliant: {2}" -f $ComputerName, $Port, $_.Exception.InnerException.Message)
    }
	catch [System.IO.IOException]
	{
		Add-Member -InputObject $result -MemberType NoteProperty -Name 'Certificate' -Value $null
		Add-Member -InputObject $result -MemberType NoteProperty -Name 'Status' -Value 'Unencrypted'

		# Usually this is because the connection isn't configured to use SSL/TLS, so can be ignored unless the port is 443
		if ($port -ne 443)
		{
			# Should we have an option to check where TLS is required, but not configured?
			Write-Host ("{0}:{1} is not configured to use SSL/TLS" -f $ComputerName, $Port)
		} else {
			Write-Warning ("{0}:{1} is not configured to use SSL/TLS despite being bound to port 443" -f $ComputerName, $Port)
			Write-EventLog -Source $EventLogSource -LogName 'Application' -EventId 7 -EntryType Warning -Message ("{0}:{1} is not configured to use SSL/TLS despite being bound to port 443" -f $ComputerName, $Port) -ErrorAction SilentlyContinue 
		}
		Write-Verbose $_
	}
	catch [System.Net.Sockets.SocketException]
	{
		Add-Member -InputObject $result -MemberType NoteProperty -Name 'Certificate' -Value $null
		Add-Member -InputObject $result -MemberType NoteProperty -Name 'Status' -Value 'Connection refused'

		# Firewall or bindings probably
		#Write-Host ("Connection refused to {0}:{1} ({2})" -f $ComputerName, $Port, $_)
		Write-Verbose $_
	}
    catch
    {
		Add-Member -InputObject $result -MemberType NoteProperty -Name 'Certificate' -Value $null
		Add-Member -InputObject $result -MemberType NoteProperty -Name 'Status' -Value $_
		Write-Warning $_	
    }
	finally
	{
		if ($ssl -ne $null)
		{
			$ssl.Close()
        }
		
		if ($client.Connected)
		{
			$client.Close()
		}
	}

	
    return $result

}

<#
	.SYNOPSIS 
	Gets a list of local TCP listening ports

	.DESCRIPTION
	Like Netstat -a, gets a list of local ports on which there's a daemon listening	

#>
function Get-LocalTcpListeningPort
{
	$result = @()
	$WindowsPorts = @(135, 139, 445, 3389)	# Always ignore these
	
    #Get IP properties (Netstat)
	[System.Net.NetworkInformation.IPGlobalProperties]$ipProperties = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    
    #Get the active listener endpoints from the IPProperties object
	[System.Net.IPEndPoint[]]$tcpEndPoints = $ipProperties.GetActiveTcpListeners() | Where-Object{ $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and ($WindowsPorts -notcontains $_.Port) }
	
    #Iterate them into an object
    foreach(  $info in $tcpEndPoints)
	{
		Write-Verbose ("{0}:{1}`tListening" -f $info.Address, $info.Port )
		$result += '' | Select-Object @{Name='Address'; Expression={ [System.Environment]::MachineName }}, @{Name='Port'; Expression={ $info.Port }}, @{Name='Proxy'; Expression={ '' }}
	}
	
	return $result

}

# Get path to self
function Get-ScriptPath()
{

	#$scriptPath = $MyInvocation.MyCommand.Path
	$scriptName = [string]$MyInvocation.ScriptName
	#$scriptPath = (Split-Path $scriptName -parent)
	#return [string]$scriptPath
	
	return $scriptName

}

function Create-ScheduledTask
{

	$legacyServer = (([System.Environment]::OSVersion.Version.Major -eq 5) -and ([System.Environment]::OSVersion.Version.Minor -eq 2))

	[string]$mypath = Get-ScriptPath
	#[string]$mypath = "H:\Dev\PowerShell\Test-SSLCertificate.ps1"
	#[string]$scriptPath = [System.IO.Path]::Combine([System.Environment]::SystemDirectory, 'Test-SslCertificate.ps1' )
	[string]$scriptPath = [System.IO.Path]::Combine([System.Environment]::GetEnvironmentVariable('SystemRoot'), 'Test-SslCertificate.ps1' )
	
	
	Write-Host "Copying $mypath to $scriptPath"
	[System.IO.File]::Copy( $mypath, $scriptPath, $true )
	
		
	if ($legacyServer)
	{
		# Win2k3 - use legacy AT scheduler
		
		# Randomise starttime by up to an hour from 03:00
		$startTime = New-Object TimeSpan( 3, 0, 0 ) 
		$startTime = $startTime.Add( [TimeSpan]::FromMinutes( (New-Object System.Random).Next(0, 60) ) )
		$startTimeString = $startTime.ToString().Substring(0, 5)
		
		# Create AT scheduled task
		$proc = (Start-Process -FilePath ("{0}\At.exe" -f [System.Environment]::SystemDirectory) -ArgumentList ("{0} /every:S PowerShell.exe -ExecutionPolicy RemoteSigned `"$scriptPath`"" -f $startTimeString) -Wait -PassThru -WindowStyle Hidden)
		
		
	} else {
		
		# Win2k8 and later task scheduler
		
		$buffer = @()	
		$buffer += "<?xml version='1.0' encoding='UTF-16'?>"
		$buffer += "<Task version='1.3' xmlns='http://schemas.microsoft.com/windows/2004/02/mit/task'>"
		$buffer += "<RegistrationInfo>"
		$buffer += "<Date>2014-08-13T11:44:28.3433193</Date>"
		$buffer += "<Author>AUAUTD0001\l016618.s</Author>"
		$buffer += "<Description>Server TLS certificate health check</Description>"
		$buffer += "</RegistrationInfo>"
		$buffer += "<Triggers>"
		$buffer += "<CalendarTrigger>"
		$buffer += "<StartBoundary>2014-08-02T03:00:00</StartBoundary>"
		$buffer += "<ExecutionTimeLimit>PT2M</ExecutionTimeLimit>"
		$buffer += "<Enabled>true</Enabled>"
		$buffer += "<RandomDelay>PT1H</RandomDelay>"
		$buffer += "<ScheduleByWeek>"
		$buffer += "<DaysOfWeek>"
		$buffer += "<Saturday />"
		$buffer += "</DaysOfWeek>"
		$buffer += "<WeeksInterval>1</WeeksInterval>"
		$buffer += "</ScheduleByWeek>"
		$buffer += "</CalendarTrigger>"
		$buffer += "</Triggers>"
		$buffer += "<Principals>"
		$buffer += "<Principal id='Author'>"
		$buffer += "<UserId>S-1-5-18</UserId>"
		$buffer += "<RunLevel>HighestAvailable</RunLevel>"
		$buffer += "</Principal>"
		$buffer += "</Principals>"
		$buffer += "<Settings>"
		$buffer += "<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>"
		$buffer += "<DisallowStartIfOnBatteries>true</DisallowStartIfOnBatteries>"
		$buffer += "<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>"
		$buffer += "<AllowHardTerminate>true</AllowHardTerminate>"
		$buffer += "<StartWhenAvailable>true</StartWhenAvailable>"
		$buffer += "<RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>"
		$buffer += "<IdleSettings>"
		$buffer += "<Duration>PT1M</Duration>"
		$buffer += "<WaitTimeout>PT1H</WaitTimeout>"
		$buffer += "<StopOnIdleEnd>true</StopOnIdleEnd>"
		$buffer += "<RestartOnIdle>false</RestartOnIdle>"
		$buffer += "</IdleSettings>"
		$buffer += "<AllowStartOnDemand>true</AllowStartOnDemand>"
		$buffer += "<Enabled>true</Enabled>"
		$buffer += "<Hidden>false</Hidden>"
		$buffer += "<RunOnlyIfIdle>false</RunOnlyIfIdle>"
		$buffer += "<DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession>"
		$buffer += "<UseUnifiedSchedulingEngine>false</UseUnifiedSchedulingEngine>"
		$buffer += "<WakeToRun>false</WakeToRun>"
		$buffer += "<ExecutionTimeLimit>PT1H</ExecutionTimeLimit>"
		$buffer += "<Priority>7</Priority>"
		$buffer += "</Settings>"
		$buffer += "<Actions Context='Author'>"
		$buffer += "<Exec>"
		$buffer += "<Command>PowerShell.exe</Command>"
		$buffer += "<Arguments>`"&amp;'$scriptPath';exit $" + "lastExitCode`"</Arguments>"
		$buffer += "</Exec>"
		$buffer += "</Actions>"
		$buffer += "</Task>"

		# Save XML file
		[string]$tempFile = [System.IO.Path]::GetTempFileName()
		Set-Content $tempFile -Force -Value $buffer -Encoding Unicode

		# Create scheduled task
		$proc = (Start-Process -FilePath ("{0}\SchTasks.exe" -f [System.Environment]::SystemDirectory) -ArgumentList ("/create /f /tn `"Certificate Health Check`" /Xml `"$tempFile`"") -Wait -PassThru -WindowStyle Hidden)
		
		# Clean up
		[System.IO.File]::Delete( $tempFile )
		
		return ($proc.ExitCode -eq 0)
	}
	
}


<#
[string]$EventLogSource = 'Certificate Health Check' 

# Register event source
New-EventLog -LogName 'Application' -Source $EventLogSource -ErrorAction SilentlyContinue


if ($Install -eq $true)
{
	Create-ScheduledTask 
	exit 0
}


if ($Filename.Length -gt 0)
{

	# web-based file?
	if ($filename -match '^http[s]?')
	{
		[string]$URL = $filename
		$filename = [System.IO.Path]::GetTempFileName()
	
		# Download from SharePoint
		[System.Net.WebClient]$webClient = New-Object system.Net.WebClient
		$webClient.UseDefaultCredentials = $true
		$webClient.DownloadFile( $URL, $filename )
	}

	# Scan a list of URL's in the supplied CSV file
	$endPoints = @()
	$buffer = Import-Csv -Path $Filename -Delimiter `t
	
	foreach ($row in $buffer)
	{
		if (($row.Address.length -gt 0) -and ($row.Address -notmatch '^;.*'))	# Ignore comments ;
		{
			if ($row.Address -match "^http\://")
			{
				Write-Warning ("Ignoring non-HTTPS address: {0}" -f $row.Address)
			}
			elseif ($row.Address -match "^https\://")
			{
				$uri = New-Object System.Uri( $row.Address )
				$endPoints += @( '' | Select-Object @{Name='Address'; Expression={ $uri.Host }}, @{Name='Port'; Expression={ $uri.Port }}, @{Name='Proxy'; Expression={ $row.Proxy }} )
			} else {
				Write-Verbose $row.Address
				$uri = New-Object System.Uri( "tcp://" + $row.Address )
				$endPoints += @( '' | Select-Object @{Name='Address'; Expression={ $uri.Host }}, @{Name='Port'; Expression={ $uri.Port }}, @{Name='Proxy'; Expression={ $row.Proxy }} )
			}
		}
	}
}
elseif (($computerName -match 'LocalHost') -or ($computerName -match [System.Environment]::MachineName))
{
	# Scan local host for listenting ports
	$endPoints = @( Get-LocalTcpListeningPort )
} else {
	# Scan the named host:port provided via the commandline
	$endPoints = @( '' | Select-Object @{Name='Address'; Expression={ $ComputerName }}, @{Name='Port'; Expression={ $Port }}, @{Name='Proxy'; Expression={ $proxy }} )
}


[int]$badCertCount = 0
[int]$i = 0
$result = @()
	
			
foreach( $endPoint in $endPoints )
{

	if (($endPoint.Proxy -ne $null) -and ($endPoint.Proxy.Length -gt 0))
	{	
		if (($endPoint.Port -ne $null) -and ($endPoint.Port -ne -1))
		{
			Write-Progress -Status ("Connecting via {0} to " -f $endPoint.Proxy) -Activity "Checking TLS/SSL certificates" -CurrentOperation ("{0}:{1}" -f $endPoint.Address, $endPoint.Port) -PercentComplete ($i/$endPoints.Count*100)
			$sslInfo = (Get-SslInfoViaProxy -URL ("https://{0}:{1}/" -f $endPoint.Address, $endPoint.Port) -proxy $endPoint.Proxy)
			$cert = $sslInfo.Certificate
		}
		else 
		{
			Write-Progress -Status ("Connecting via {0} to " -f $endPoint.Proxy) -Activity "Checking TLS/SSL certificates" -CurrentOperation ("{0}:{1}" -f $endPoint.Address, 443) -PercentComplete ($i/$endPoints.Count*100)
			 $sslInfo = (Get-SslInfoViaProxy -URL ("https://{0}:{1}/" -f $endPoint.Address, 443) -proxy $endPoint.Proxy)
			 $cert = $sslInfo.Certificate
		}	
	} else {
		if (($endPoint.Port -ne $null) -and ($endPoint.Port -ne -1))
		{
			Write-Progress -Status "Connecting to " -Activity "Checking TLS/SSL certificates" -CurrentOperation ("{0}:{1}" -f $endPoint.Address, $endPoint.Port) -PercentComplete ($i/$endPoints.Count*100)
			$sslInfo = Get-SslInfo -ComputerName $endPoint.Address -port $endPoint.Port
			$cert = $sslInfo.Certificate
		} else {
			Write-Progress -Status "Connecting to " -Activity "Checking TLS/SSL certificates" -CurrentOperation ("{0}:{1}" -f $endPoint.Address, 443) -PercentComplete ($i/$endPoints.Count*100)
			$sslInfo = Get-SslInfo -ComputerName $endPoint.Address -port 443
			$cert = $sslInfo.Certificate
		}
	}


	# Found a SSL cert to inspect
	if ($cert -ne $null)
	{

		# Some basic cert properties for debugging
		Write-Verbose $cert.Subject
		Write-Verbose $cert.Thumbprint
		Write-Verbose $cert.Issuer
		Write-Verbose $cert.NotAfter
		Write-Verbose $cert.NotBefore
		Write-Verbose $cert.SignatureAlgorithm.FriendlyName
		
		# Check certificate chain & verify trust & hashing algorithm
		
		try
		{
			# [bool]$SecureChain = $cert.Verify()	 	# Useless - fails if the CRL URL is inaccessible!
			$certChain = new-object System.Security.Cryptography.X509Certificates.X509Chain
			$certChain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
			$certChain.ChainPolicy.RevocationFlag = [System.Security.Cryptography.X509Certificates.X509RevocationFlag]::EntireChain
			$certChain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::IgnoreCtlSignerRevocationUnknown
			$SecureChain = $certChain.Build($cert)

			if (!$SecureChain)
			{
				Write-Warning ("Certificate {0} ({1}) is not trusted" -f $cert.Subject, $cert.ThumbPrint )
				$status = 'Untrusted cert'
				$secureCert = $false
				
			} else {

				# Check for MD5 hashing
				if ($cert.SignatureAlgorithm.FriendlyName -match 'MD5')
				{
					$SecureCert =  $false
					$status = 'Insecure hash'
					Write-EventLog -Source $EventLogSource -LogName 'Application' -EventId 40 -EntryType Warning -Message ("Certificate {0} ({1}) at {2}:{3} is using MD5 hashing" -f $cert.Subject, $cert.Thumbprint, $endPoint.Address, $endPoint.Port ) -ErrorAction SilentlyContinue
					Write-Warning ("Certificate {0} ({1}) at {2}:{3} is using MD5 hashing" -f $cert.Subject, $cert.Thumbprint, $endPoint.Address, $endPoint.Port )
					$secureCert = $false
				}
				# Check for legacy SHA-1 hashing
				elseif ($cert.SignatureAlgorithm.FriendlyName -match 'SHA1')
				{
					$SecureCert =  $false
					$status = 'Insecure hash'
					Write-EventLog -Source $EventLogSource -LogName 'Application' -EventId 41 -EntryType Warning -Message ("Certificate {0} ({1}) at {2}:{3} is using SHA-1 hashing" -f $cert.Subject, $cert.Thumbprint, $endPoint.Address, $endPoint.Port ) -ErrorAction SilentlyContinue
					Write-Warning ("Certificate {0} ({1}) at {2}:{3} is using SHA-1 hashing" -f $cert.Subject, $cert.Thumbprint, $endPoint.Address, $endPoint.Port )
					$secureCert = $false
				} else {
					Write-Host ("Certificate {0} ({1}) at {2}:{3} is using SHA-2 hashing" -f $cert.Subject, $cert.Thumbprint, $endPoint.Address, $endPoint.Port )
					$secureCert = $true
				}
				
				
				# Check that the public key size is big enough that it can't be brute-forced
				if ($cert.PublicKey.Key.KeySize -ge 1024)
				{
					Write-Host ("Certificate {0} ({1}) is trusted" -f $cert.Subject, $cert.ThumbPrint )
				} else
				{
					Write-Warning ("Certificate {0} ({1}) is trusted, but has a public key that's too small" -f $cert.Subject, $cert.ThumbPrint )
					Write-EventLog -Source $EventLogSource -LogName 'Application' -EventId 42 -EntryType Warning -Message ("Certificate {0} ({1}) at {2}:{3} is using an insecure public key size" -f $cert.Subject, $cert.Thumbprint, $endPoint.Address, $endPoint.Port ) -ErrorAction SilentlyContinue
					Write-Warning ("Certificate {0} ({1}) at {2}:{3} is using an insecure public key size" -f $cert.Subject, $cert.Thumbprint, $endPoint.Address, $endPoint.Port )
					$status = 'Insecure public key'
					$secureCert = $false
				}
			}
			
			
			# Check for self-signed certs
			if (!$secureCert)
			{
				# Ignore for now
			}
			elseif ($certChain.ChainElements.Count -gt 1)
			{
				Write-Host ("{0} certificate(s) in the chain" -f $certChain.ChainElements.Count)
				Write-Host ("Issuer is {0}" -f $cert.Issuer )
			} else {
				$status = 'Self-signed cert'
				Write-Warning ("Certificate {0} ({1}) is self-signed" -f $cert.Subject, $cert.ThumbPrint )
				$secureCert = $false
			}
			
		}
		catch
		{
			# Will this ever happen?
			Write-Warning $_
		}
		
		
		# How long before Cinderella turns into a pumpkin?
		$timeToExpiry = $cert.NotAfter.Subtract( [DateTime]::Now )
		
		if (!$secureCert)
		{
		}		
		elseif ($timeToExpiry.TotalSeconds -lt 0)
		{
			$status = 'Expired'
			$badCertCount++
			if ($SecureChain)
			{
				Write-EventLog -Source $EventLogSource -LogName 'Application' -EventId 6 -EntryType Error -Message ("Certificate {0} ({1}) at {2}:{3} expired on {4}" -f $cert.Subject, $cert.Thumbprint, $endPoint.Address, $endPoint.Port, $cert.NotAfter ) -ErrorAction SilentlyContinue
				Write-Warning ("Certificate {0} ({1}) at {2}:{3} expired on {4}" -f $cert.Subject, $cert.Thumbprint, $endPoint.Address, $endPoint.Port, $cert.NotAfter )
			} else {
				Write-EventLog -Source $EventLogSource -LogName 'Application' -EventId 5 -EntryType Error -Message ("Certificate {0} ({1}) at {2}:{3} expired on {4}" -f $cert.Subject, $cert.Thumbprint, $endPoint.Address, $endPoint.Port, $cert.NotAfter ) -ErrorAction SilentlyContinue
				Write-Warning ("Self-signed certificate {0} ({1}) at {2}:{3} expired on {4}" -f $cert.Subject, $cert.Thumbprint, $endPoint.Address, $endPoint.Port, $cert.NotAfter )
			}
		}
		elseif ($timeToExpiry.TotalDays -lt $WarningPeriod)
		{
			if ($SecureChain)
			{
				$status = 'Expiring soon'
				Write-EventLog -Source $EventLogSource -LogName 'Application' -EventId 4 -EntryType Warning -Message ("Certificate {0} ({1}) at {2}:{3} will expire in {4:0} day(s)" -f $cert.Subject, $cert.Thumbprint, $endPoint.Address, $endPoint.Port, $timeToExpiry.TotalDays ) -ErrorAction SilentlyContinue
				Write-Warning ("Certificate {0} ({1}) at {2}:{3} will expire in {4:0} day(s)" -f $cert.Subject, $cert.Thumbprint, $endPoint.Address, $endPoint.Port, $timeToExpiry.TotalDays )
			} else {
				$status = 'Expiring soon (Self-signed)'
				Write-EventLog -Source $EventLogSource -LogName 'Application' -EventId 3 -EntryType Warning -Message ("Certificate {0} ({1}) at {2}:{3} will expire in {4:0} day(s)" -f $cert.Subject, $cert.Thumbprint, $endPoint.Address, $endPoint.Port, $timeToExpiry.TotalDays ) -ErrorAction SilentlyContinue
				Write-Warning ("Self-signed certificate {0} ({1}) at {2}:{3} will expire in {4:0} day(s)" -f $cert.Subject, $cert.Thumbprint, $endPoint.Address, $endPoint.Port, $timeToExpiry.TotalDays )
			}
		} 
		else 
		{
			if ($SecureChain)
			{
				$status = 'OK'
				Write-EventLog -Source $EventLogSource -LogName 'Application' -EventId 2 -EntryType Information -Message ("Certificate {0} ({1}) at {2}:{3} expires in {4:0} day(s) and is therefore OK" -f $cert.Subject, $cert.Thumbprint, $endPoint.Address, $endPoint.Port, $timeToExpiry.TotalDays ) -ErrorAction SilentlyContinue
				Write-Host -ForegroundColor Green ("Certificate {0} ({1}) at {2}:{3} expires in {4:0} day(s) and is therefore OK" -f $cert.Subject, $cert.Thumbprint, $endPoint.Address, $endPoint.Port, $timeToExpiry.TotalDays )
			} else {
				$status = 'Self-signed'			
				Write-EventLog -Source $EventLogSource -LogName 'Application' -EventId 1 -EntryType Warning -Message ("Certificate {0} ({1}) at {2}:{3} expires in {4:0} day(s), but is self-signed" -f $cert.Subject, $cert.Thumbprint, $endPoint.Address, $endPoint.Port, $timeToExpiry.TotalDays ) -ErrorAction SilentlyContinue
				Write-Warning ("Self-signed certificate {0} ({1}) at {2}:{3} expires in {4:0} day(s)" -f $cert.Subject, $cert.Thumbprint, $endPoint.Address, $endPoint.Port, $timeToExpiry.TotalDays )
			}
		}
		
		$row = New-Object -TypeName PSObject
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Address' -Value $endPoint.Address
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Port' -Value $endPoint.Port
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Protocol' -Value $sslInfo.Protocol
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Cipher' -Value $sslInfo.Cipher		
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Connection Status' -Value $sslInfo.Status
		
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Cert subject' -Value $cert.Subject
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Cert thumbprint' -Value $cert.Thumbprint
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Cert Issuer' -Value $cert.Issuer
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Cert Issed' -Value $cert.NotBefore
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Cert Expiry' -Value $cert.NotAfter
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Cert Key Size' -Value $cert.PublicKey.Key.KeySize
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Cert Chain Trusted' -Value $SecureChain
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Cert Hash type' -Value $cert.SignatureAlgorithm.FriendlyName
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Cert Status' -Value $status
		
		$result += $row

		# Save the cert to a file if requested
		if ($backupPath.length -gt 0)
		{
			[System.IO.Directory]::CreateDirectory( $backupPath )
			[string]$certFilename = [System.IO.Path]::Combine( $backupPath, $endPoint.Address + '.cer' )
			$certRaw = $cert.Export( [System.Security.Cryptography.X509Certificates.X509ContentType]::Cert )
			Write-Host "Saving $certFilename"
			Set-Content -Path $certFilename -Value $certRaw -Encoding Byte -Force
		}	


	} else {

		$row = New-Object -TypeName PSObject
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Address' -Value $endPoint.Address
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Port' -Value $endPoint.Port
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Protocol' -Value $sslInfo.Protocol
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Cipher' -Value $sslInfo.Cipher		
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Connection Status' -Value $sslInfo.Status
		
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Cert subject' -Value ''
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Cert thumbprint' -Value ''
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Cert Issuer' -Value ''
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Cert Issed' -Value ''
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Cert Expiry' -Value ''
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Cert Key Size' -Value ''
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Cert Chain Trusted' -Value $false
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Cert Hash type' -Value ''
		Add-Member -InputObject $row -MemberType NoteProperty -Name 'Cert Status' -Value 'Not found'
		
		$result += $row
	
	}

	$result += $row

	$i++

}

Write-Host "$badCertCount bad cert(s) found"

$result 

#>