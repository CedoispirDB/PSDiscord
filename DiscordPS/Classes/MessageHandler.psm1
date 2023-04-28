class MessageHandler {

    [string] $clientToken

    MessageHandler (
        [string] $clientToken
    ) {
        $this.clientToken = $clientToken
    }

    [void] Send([string] $message, [string] $channelId) {
        $url = "https://discord.com/api/channels/$channelId/messages"
        $headers = @{
            "Authorization" = "Bot $($this.clientToken)"
            "Content-Type" = "application/json"
            "User-Agent" = "DiscordBot (https://example.com, 10)"
        
        }
        
        $body = @{
            "content" = $message
            "tts" = $false
        } | ConvertTo-Json
        
        Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $body
        
    } 
}