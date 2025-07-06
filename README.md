# sm-plugin-ServerCommandFilter
- Filters point_servercommand->Command() using user-defined rules to restrict maps.
- Filters all convars changes performed via VScript
- Filters all commands performed via VScript

> [!IMPORTANT]
> Upgrade from 1.x to 2.x introduce a config change in sourcemod/configs.

- Rename: PointServerCommandFilter.cfg -> ServerCommandFilter.cfg
- Update the KeyValue inside your new PointServerCommandFilter.cfg "PointServerCommandFilter" -> "ServerCommandFilter"
