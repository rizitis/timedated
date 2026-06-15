/*
 * OPTIONAL / ALTERNATIVE implementation of handle_set_time().
 *
 * This is NOT currently used by the daemon.
 *
 * The default handle_set_time() returns an error when NTP is running,
 * requiring the user/client to disable NTP first (via SetNTP false)
 * before calling SetTime. KDE Plasma already does this automatically.
 *
 * This alternative version instead mimics systemd-timedated behaviour:
 * it automatically stops and disables the NTP daemon before setting
 * the time. Swap it into rcl-timedate.c only if a client is found that
 * calls SetTime without first disabling NTP.
 * NOTE: Plasma DONT need it so far,only a 3rd part guiapp might need it
 */

gboolean handle_set_time( RclTimedateDaemon     *object,
                          GDBusMethodInvocation *invocation,
                          gint64                 usec_utc,
                          gboolean               relative,
                          gboolean               interactive,
                          RclDaemon             *daemon )
{
  struct set_time_data *data;
  guint64               start;

  if( ntp_daemon_installed() && ntp_daemon_enabled() && ntp_daemon_status() )
  {
    /* NTP Daemon is running — stop it automatically (like systemd-timedated does) */
    g_debug( "set-time: NTP is running, stopping it before setting time" );

    if( !stop_ntp_daemon() )
    {
      g_debug( "set-time: error: Cannot stop NTP daemon" );
      g_dbus_method_invocation_return_error( invocation,
                                             RCL_DAEMON_ERROR,
                                             RCL_DAEMON_ERROR_GENERAL,
                                             "set-time: Cannot stop NTP daemon" );
      return TRUE;
    }

    if( !disable_ntp_daemon() )
    {
      g_debug( "set-time: warning: NTP daemon stopped but could not be disabled" );
    }

    daemon->priv->use_ntp = FALSE;
    rcl_timedate_daemon_set_ntp( object, FALSE );

    g_debug( "set-time: NTP daemon stopped successfully" );
  }

  start = now( CLOCK_MONOTONIC );

  if( !relative && usec_utc <= 0 )
  {
    g_debug( "set-time: error: Invalid absolute time" );
    g_dbus_method_invocation_return_error( invocation,
                                           RCL_DAEMON_ERROR,
                                           RCL_DAEMON_ERROR_INVALID_ARGS,
                                           "set-time: Invalid absolute time" );
    return TRUE;
  }

  if( relative && usec_utc == 0 )
  {
    /* Nothing to do */
    rcl_timedate_daemon_complete_set_time( object, invocation );
    return TRUE;
  }

  data = g_new0( struct set_time_data, 1 );
  data->object      = object;
  data->invocation  = invocation;
  data->start       = start;
  data->usec_utc    = usec_utc;
  data->relative    = relative;
  data->interactive = interactive;
  data->daemon      = daemon;

  _check_polkit_for_action_async( invocation,
                                  "set-time",
                                  interactive,
                                  set_time_authorized_callback,
                                  data );
  return TRUE;
}
