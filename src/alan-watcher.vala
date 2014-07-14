/*
 * vera-plugin-alan-watcher - alan-watcher plugin for vera
 * Copyright (C) 2014  Eugenio "g7" Paolantonio and the Semplice Project
 * 
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 * 
 * Authors:
 *    Eugenio "g7" Paolantonio <me@medesimo.eu>
*/

using Vera;
using Nala;

namespace AlanWatcherPlugin {

	public class QueueHandler {
		/** Handler for the Queue. **/
		
		private Nala.Queue queue;
		
		public QueueHandler(Nala.Queue queue) {
			this.queue = queue;
		}
		
		public void add_to_queue(Nala.WatcherPool pool, Nala.Watcher watcher, File trigger, FileMonitorEvent event) {
			/** This method is fired when some event happened in our watcher/watcherpool. **/
			
			message("Adding to queue, %s\n", trigger.get_path());
			this.queue.add_to_queue(watcher, trigger, event);
		}
		
	}
	
	public class Plugin : Peas.ExtensionBase, VeraPlugin {

		uint[] TimeoutList = new uint[0];
			
		Nala.WatcherPool pool = new Nala.WatcherPool();
		Nala.Queue queue = new Nala.Queue(3);
		QueueHandler queueh;
		Gee.HashMap<string, Nala.Application> applications_objects = new Gee.HashMap<string, Nala.Application>();


		private void reconfigure_openbox() {
			/** Reconfigures openbox. **/
			
			try {
				Process.spawn_command_line_sync("openbox --reconfigure");
			} catch (SpawnError e) {
				warning("ERROR: Unable to reconfigure openbox: %s\n", e.message);
			}
		
		}
		
		private void update_menu(Nala.Queue queue, Nala.Application[] apps, Array<string> in_queue_path, Array<string> in_queue_trigger, Array<FileMonitorEvent> in_queue_event) {
			/** Called when the queue timeout finishes. This method updates the menu. **/

			foreach(Nala.Application app in apps) {
				message("Regenerating %s\n", app.path);
				
				try {
					Process.spawn_command_line_sync("alan-menu-updater -p vera -i ~/.config/vera " + app.path);
				} catch (SpawnError e) {
					warning("ERROR: Unable to update menu: %s\n", e.message);
				}
			}
			
			reconfigure_openbox();
		}
		
		private void update_menu_simple(Nala.Application app) {
			/** Do what update_menu() does, in a simple single way. **/
			
			message("Regenerating %s\n", app.path);
			
			try {
				Process.spawn_command_line_sync("alan-menu-updater -p vera -i ~/.config/vera " + app.path);
			} catch (SpawnError e) {
				warning("ERROR: Unable to update menu: %s\n", e.message);
			}
			
			reconfigure_openbox();
		}
		
		private void init(Display display) {
			/** Hello! **/
			
			this.queueh = new QueueHandler(queue);
			
			pool.watcher_changed.connect(queueh.add_to_queue);
			queue.processable.connect(update_menu);

			// Wanna some setup?
			var dir = File.new_for_path(Environment.get_home_dir() + "/.config/vera/alan-menus");
			if (!dir.query_exists()) {
				// Check for livemode, and if we are in nolock
				var livemode = File.new_for_path("/etc/semplice-live-mode");
				if (livemode.query_exists()) {
					// We are in live, read /etc/semplice-live-mode to get
					// current mode.
					string line = "nolock";
					try {
						var inputstream = new DataInputStream(livemode.read());
						line = inputstream.read_line().replace("\n","");
					} catch {
						warning("Unable to open inputstream.");
					}
					
					if (line != "nolock") {
						// still initializing, do not need setup now.
						message("Not doing alan2 setup now, user still outside of nolock mode.");
						return;
					}
				}
				
				// Doing setup
				try {
					// FIXME: semplice-vera is hardcoded
					Process.spawn_command_line_sync("/usr/share/alan2/alan2-setup.sh semplice-vera");
				} catch (SpawnError e) {
					warning("ERROR: Unable to setup alan2: %s\n", e.message);
				}
				
				
				reconfigure_openbox();
			}
		
		}
		
		private void startup(StartupPhase phase) {
			/** startup **/
			
			if (phase != StartupPhase.OTHER)
				return;
			
			// Parse watchers
			try {
				var watcher_directory = File.new_for_path("/etc/alan/watchers");
				var watcher_enumerator = watcher_directory.enumerate_children(FileAttribute.STANDARD_NAME, 0);
				FileInfo file_info;
				while ((file_info = watcher_enumerator.next_file()) != null) {
					KeyFile watcher = new KeyFile();
					watcher.load_from_file("/etc/alan/watchers/" + file_info.get_name(), KeyFileFlags.NONE);
					string application = watcher.get_string("nala", "application");				
					
					// Get files
					string[] files = new string[0];
					if (watcher.has_key("nala", "files")) {
						foreach(string file in watcher.get_string("nala", "files").split(" ")) {
							files += file.replace("~", Environment.get_home_dir());
						}
					}
					files += "/etc/alan/alan-vera.conf";
					files += Environment.get_home_dir() + "/.config/vera/alan/alan-vera.conf";

					// Generate application
					Nala.Application app = new Nala.Application(application, files);

					// Check for timer
					if (watcher.has_key("nala", "timer")) {
						// Yeah!
						TimeoutList += Timeout.add_seconds_full(
							Priority.DEFAULT,
							watcher.get_integer("nala", "timer"),
							() => {
								update_menu_simple(app);
								return true;
							}
						);
					}
					
					// should refresh on first start?
					if (watcher.has_key("nala", "refresh_on_start")) {					
						if (watcher.get_boolean("nala", "refresh_on_start")) {
							Timeout.add_seconds(
								2,
								() => {
									message("Refreshing because of refresh_on_start in watcher...");
									// Ok, let's make a call to update_menu_simple.
									update_menu_simple(app);
									
									return false;
								}
							);
						}
					}
					
					// add application to pool and queue
					applications_objects[application] = app;
					pool.add_watchers(app.triggers);
					queue.add_application(app);
				}
			} catch (Error e) {
				warning("ERROR: Unable to access to the watchers directory.");
			}
		}
		
		/* FIXME */
		private void shutdown() {}
	}
}


[ModuleInit]
public void peas_register_types(GLib.TypeModule module)
{
	Peas.ObjectModule objmodule = module as Peas.ObjectModule;
	objmodule.register_extension_type(typeof(VeraPlugin), typeof(AlanWatcherPlugin.Plugin));
}
