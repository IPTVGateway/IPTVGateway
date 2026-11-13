object IPTVGatewayService: TIPTVGatewayService
  AllowPause = False
  DisplayName = 'IPTV Gateway'
  OnCreate = ServiceCreate
  OnDestroy = ServiceDestroy
  OnShutdown = ServiceShutdown
  OnStart = ServiceStart
  OnStop = ServiceStop
  Height = 150
  Width = 215
end
