/* gnome-linto
 *
 * Copyright (C) 2026 Benjamin Bellamy
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published
 * by the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include "netinfo.h"

#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>

char *
linto_iface_for_ip (const char *ip, gboolean *is_up)
{
  struct ifaddrs *ifaddr, *ifa;
  char *result = NULL;

  if (is_up != NULL)
    *is_up = FALSE;

  if (ip == NULL || getifaddrs (&ifaddr) == -1)
    return NULL;

  for (ifa = ifaddr; ifa != NULL; ifa = ifa->ifa_next)
    {
      char host[INET_ADDRSTRLEN];
      struct sockaddr_in *sin;

      if (ifa->ifa_addr == NULL || ifa->ifa_addr->sa_family != AF_INET)
        continue;

      sin = (struct sockaddr_in *) ifa->ifa_addr;
      if (inet_ntop (AF_INET, &sin->sin_addr, host, sizeof (host)) == NULL)
        continue;

      if (g_strcmp0 (host, ip) == 0)
        {
          result = g_strdup (ifa->ifa_name);
          if (is_up != NULL)
            *is_up = (ifa->ifa_flags & IFF_UP) && (ifa->ifa_flags & IFF_RUNNING);
          break;
        }
    }

  freeifaddrs (ifaddr);
  return result;
}
