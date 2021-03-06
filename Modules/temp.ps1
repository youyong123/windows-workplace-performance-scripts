Import-Csv -Path ..\Host_User.csv -Delimiter `t | foreach { 
        Write-Host Invoke-Command -credential $credential `
         -ComputerName $_.Hostname `
         -scriptBlock { 
            Net LocalGroup `"Netmon Users`" /add CORPAU\$_.UserName 
         } 
      }