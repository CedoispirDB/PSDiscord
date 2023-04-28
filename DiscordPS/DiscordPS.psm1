using namespace System
using namespace System.Text
using namespace System.Net.WebSockets
using namespace System.Threading
using namespace System.Threading.Tasks

using module ./Classes/MessageHandler.psm1

class Client {
    [ClientWebSocket] $webSocket
    [Task] $connectTask
    [string] $clientToken
    [string] $webSocketUrl = "wss://gateway.discord.gg/?v=10&encoding=json"
    [ArraySegment[Byte]] $responseSegment
    [StringBuilder] $currentResponse
    [PSCustomObject] $lastEventData

    [string] $opcode # Gateway opcode
    [string] $prevSequence # Last sequence number of event
    [int] $heartbeatInterval # heartbeat interval
    [int] $intends = 40719
    [long] $lastHeartbeatsent

    [MessageHandler] $messageHandler

    Client(
        [string] $clientToken
    ) {
        $this.clientToken = $clientToken
        $this.responseSegment = [ArraySegment[Byte]]::new([System.Byte[]]::new(4092));
        $this.currentResponse = [StringBuilder]::new()
        $this.webSocket = [ClientWebSocket]::new()

        $this.messageHandler = [MessageHandler]::new($clientToken)
        
    }

    [bool] Init() {
        $this.connectTask = $this.webSocket.ConnectAsync($this.webSocketUrl, [CancellationToken]::new($false))

        # Check if websocket connect succesfully
        While (!$this.connectTask.IsCompleted) { 
            Start-Sleep -Milliseconds 100 
        }

        while ($this.webSocket.State -eq 'Open') {
            $this.GetResponse($false)


            $response = $this.currentResponse.ToString()
            # Write-Host "Response: " $response
            $responseJson = ConvertFrom-Json $response

            $this.opcode = $responseJson.op
            $this.prevSequence = $responseJson.s
            $eventName = $responseJson.t

            # Write-Warning "opcode: $($this.opcode)"
            # Write-Warning "prevSequence: $($this.prevSequence)"

            if ($this.opcode -eq 10) {
                # Send first heartbeat
                $this.heartbeatInterval = $responseJson.d.heartbeat_interval
                
                Start-Sleep -Milliseconds ($this.heartbeatInterval * (Get-Random -Minimum 0 -Maximum 1000) / 1000)
                
                $this.SendHeartbeat()
            }
            elseif ($this.opcode -eq 11) {
                # Send the intends
                $identifyPayload = @{
                    op = 2
                    d  = @{
                        intents    = $this.intends
                        token      = $this.clientToken
                        properties = @{
                            os      = "windows"
                            browser = "PowerShell"
                            device  = "PowerShell"
                        }
                    }
                } | ConvertTo-Json
                $identifyPayloadBuffer = [Encoding]::UTF8.GetBytes($identifyPayload)
                $messageType = [WebSocketMessageType]::Text
                $sendTask = $this.webSocket.SendAsync([ArraySegment[Byte]]::new($identifyPayloadBuffer), $messageType, $true, [CancellationToken]::new($false))
                While (!$sendTask.IsCompleted) { 
                    Write-Warning "opcode 10: send task not completed"
                    Start-Sleep -Milliseconds 100 
                }

                $this.lastHeartbeatsent = $this.CurrentTime()             
            }
            elseif ($eventName -eq "READY") {
                # Connection Established
                # TODO: Save ready data
                [void]$this.currentResponse.Clear()
                Write-Host "Connection established!" -ForegroundColor Cyan
                return $true

            }
            elseif ($this.opcode -eq 9 -or $null -eq $this.opcode) {
                Write-Error "Error on intital handshake"
                break
            }

            [void]$this.currentResponse.Clear()


        }

        # Connection closed for some reason
        Write-Error "Websocket connection close. Close status: $($this.webSocket.CloseStatus))"
        return $false

    }

    [PSCustomObject] Listen() {
        
        if ($this.webSocket.State -ne 'Open') {
            # Connection closed for some reason
            Write-Error "Websocket connection close. Close status: $($this.webSocket.CloseStatus))"
            return $null
        }
    
        $this.GetResponse($true)


        $responseJSON = $this.currentResponse.ToString()
        Write-Host "Response: " $responseJSON
        $response = ConvertFrom-Json $responseJSON
        
        $this.opcode = $response.op
        $this.prevSequence = $response.s
        $eventName = $response.t
        $this.lastEventData = $response.d

        Write-Warning "opcode: $($this.opcode)"
        Write-Warning "prevSequence: $($this.prevSequence)" 

        if ($this.opcode -eq 0) {
            # Event received

            [void]$this.currentResponse.Clear()
            
            return $this.lastEventData


        } 
        elseif ($this.opcode -eq 11) {
            # Received Heartbeat ACK
            $this.lastHeartbeatsent = $this.CurrentTime()
        }
        elseif ($this.opcode -eq 1) {
            # Immediatally send heartbeat
            $this.SendHeartbeat()
        }
        elseif ($this.opcode -eq 9 -or $null -eq $this.opcode) {
            Write-Error "Error on listener"
            break
        }

        [void]$this.currentResponse.Clear()

        return $null
    
    }

    [void] GetResponse([bool]$canSend) {
        $task = $null
        while ($null -eq $task -or !$task.Result.EndOfMessage) {
            $task = $this.webSocket.ReceiveAsync($this.responseSegment, [CancellationToken]::new($false))
            While (!$task.IsCompleted) { 
                # Check if heatbeatinterval passed
                # if($canSend) {
                #     Write-Host "Elapsed: " ($this.CurrentTime() - $this.lastHeartbeatsent) -ForegroundColor Cyan
                # }
                if ($canSend -and ($this.CurrentTime() - $this.lastHeartbeatsent) -ge $this.heartbeatInterval) {
                    $this.SendHeartbeat()
                }
                Start-Sleep -Milliseconds 100 
            }
            
            # Write-Host ($task.Result.Count)
            # Write-Host ([Encoding]::UTF8.GetString($this.responseSegment, 0, $task.Result.Count))
            # Write-Host "Current response $($this.currentResponse)"
            [void]$this.currentResponse.Append([Encoding]::UTF8.GetString($this.responseSegment, 0, $task.Result.Count))
            $this.responseSegment = [ArraySegment[Byte]]::new([System.Byte[]]::new(4092));
        }
    }

    [void] SendHeartbeat() {
        Write-Host "Sending heartbeat" -ForegroundColor Magenta
        $heartbeatPayload = @{
            op = 1
            d  = $this.prevSequence
        } | ConvertTo-Json
        $heartbeatPayloadBuffer = [Encoding]::UTF8.GetBytes($heartbeatPayload)
        $messageType = [WebSocketMessageType]::Text
        $sendTask = $this.webSocket.SendAsync([System.ArraySegment[Byte]]::new($heartbeatPayloadBuffer), $messageType, $true, [CancellationToken]::new($false))

        While (!$sendTask.IsCompleted) { 
            Write-Warning "Send heartbeat: send task not completed"
            Start-Sleep -Milliseconds 100 
        }
    }

    [long] CurrentTime() {
        return [Math]::Round((Get-Date).ToFileTime() / 10000)
    }
}

