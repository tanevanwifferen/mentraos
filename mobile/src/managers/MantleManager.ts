import socketComms from "@/managers/SocketComms"
import * as Calendar from "expo-calendar"
import restComms from "@/managers/RestComms"
import * as TaskManager from "expo-task-manager"
import * as Location from "expo-location"
import TranscriptProcessor from "@/utils/TranscriptProcessor"
import {useSettingsStore, SETTINGS_KEYS} from "@/stores/settings"
import bridge from "@/bridge/MantleBridge"

const LOCATION_TASK_NAME = "handleLocationUpdates"

TaskManager.defineTask(
  LOCATION_TASK_NAME,
  async ({data, error}: TaskManager.TaskManagerTaskBody<{locations: Location.LocationObject[]}>) => {
    if (error) {
      // check `error.message` for more details.
      console.error("Error handling location updates", error)
      return
    }
    const locs = (data?.locations ?? []) as Location.LocationObject[]
    if (!locs || locs.length === 0) {
      console.log("Mantle: LOCATION: No locations received")
      return
    }

    console.log("Received new locations", data?.locations)
    const first = locs[0]!

    const mm = MantleManager.getInstance()
    // Update cache if we got a good fix
    mm.updateLocationCacheIfGood(first)

    // Choose the best location to send (prefer cached good fix within TTL)
    const best = mm.getBestLocationForSend(first)
    if (!best) {
      console.log("Mantle: LOCATION: No best location available to send")
      return
    }

    const {coords} = best
    socketComms.sendLocationUpdate(coords.latitude, coords.longitude, coords.accuracy ?? undefined)
  },
)

class MantleManager {
  private static instance: MantleManager | null = null

  private calendarSyncTimer: NodeJS.Timeout | null = null
  private transcriptProcessor: TranscriptProcessor
  private clearTextTimeout: NodeJS.Timeout | null = null
  private readonly MAX_CHARS_PER_LINE = 30
  private readonly MAX_LINES = 3
  private locationUpdatesActive = false
  private locationUpdatesStarting = false
  private locationUpdatesStopping = false
  private wantLocationUpdates = false
  private isHeadUp = false
  private cachedLocationTier: string | null = null
  private locationUpdatesMode: "head_up" | "always_on" = "head_up"
  // Cache a good GPS lock for 5 minutes to avoid degrading to worse fixes
  private lastGoodLocation: {latitude: number; longitude: number; accuracy?: number; timestamp: number} | null = null
  private readonly GOOD_ACCURACY_METERS = 50
  private readonly CACHE_TTL_MS = 5 * 60 * 1000

  public static getInstance(): MantleManager {
    if (!MantleManager.instance) {
      MantleManager.instance = new MantleManager()
    }
    return MantleManager.instance
  }

  private constructor() {
    this.transcriptProcessor = new TranscriptProcessor(this.MAX_CHARS_PER_LINE, this.MAX_LINES)
  }

  // run at app start on the init.tsx screen:
  // should only ever be run once
  public async init() {
    try {
      const loadedSettings = await restComms.loadUserSettings() // get settings from server
      await useSettingsStore.getState().setManyLocally(loadedSettings) // write settings to local storage
      await useSettingsStore.getState().initUserSettings() // initialize user settings
    } catch (e) {
      console.error(`Failed to get settings from server: ${e}`)
    }
    await bridge.updateSettings(useSettingsStore.getState().getCoreSettings()) // send settings to core
    this.setupPeriodicTasks()
  }

  public cleanup() {
    // Stop timers
    if (this.calendarSyncTimer) {
      clearInterval(this.calendarSyncTimer)
      this.calendarSyncTimer = null
    }
    this.wantLocationUpdates = false
    this.isHeadUp = false
    void this.stopLocationUpdatesIfNeeded()
    this.transcriptProcessor.clear()
  }

  private async setupPeriodicTasks() {
    this.sendCalendarEvents()
    // Calendar sync every hour
    this.calendarSyncTimer = setInterval(
      () => {
        this.sendCalendarEvents()
      },
      60 * 60 * 1000,
    ) // 1 hour
    try {
      const storedTier = await useSettingsStore.getState().loadSetting(SETTINGS_KEYS.location_tier)
      this.cachedLocationTier = typeof storedTier === "string" ? storedTier : null
    } catch (error) {
      console.error("Mantle: Error loading location tier", error)
      this.cachedLocationTier = null
    }

    try {
      const hasStarted = await Location.hasStartedLocationUpdatesAsync(LOCATION_TASK_NAME)
      if (hasStarted) {
        await Location.stopLocationUpdatesAsync(LOCATION_TASK_NAME)
      }
      this.locationUpdatesActive = false
      this.wantLocationUpdates = false
    } catch (error) {
      console.error("Mantle: Error stopping existing location updates", error)
    }

    try {
      const storedMode = await useSettingsStore.getState().loadSetting(SETTINGS_KEYS.location_updates_mode)
      await this.applyLocationUpdatesMode(typeof storedMode === "string" ? storedMode : null)
    } catch (error) {
      console.error("Mantle: Error applying location updates mode", error)
      await this.applyLocationUpdatesMode(null)
    }
  }

  private async sendCalendarEvents() {
    try {
      console.log("Mantle: sendCalendarEvents()")
      const calendars = await Calendar.getCalendarsAsync(Calendar.EntityTypes.EVENT)
      const calendarIds = calendars.map((calendar: Calendar.Calendar) => calendar.id)
      // from 2 hours ago to 1 week from now:
      const startDate = new Date(Date.now() - 2 * 60 * 60 * 1000)
      const endDate = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000)
      const events = await Calendar.getEventsAsync(calendarIds, startDate, endDate)
      restComms.sendCalendarData({events, calendars})
    } catch (error) {
      // it's fine if this fails
      console.log("Mantle: Error sending calendar events", error)
    }
  }

  private async sendLocationUpdates() {
    console.log("Mantle: sendLocationUpdates()")
    // const location = await Location.getCurrentPositionAsync()
    // socketComms.sendLocationUpdate(location)
  }

  private async resolveLocationTier(): Promise<string | null> {
    if (this.cachedLocationTier === null) {
      try {
        const storedTier = await useSettingsStore.getState().loadSetting(SETTINGS_KEYS.location_tier)
        this.cachedLocationTier = typeof storedTier === "string" ? storedTier : null
      } catch (error) {
        console.error("Mantle: Error resolving location tier", error)
        this.cachedLocationTier = null
      }
    }

    return this.cachedLocationTier
  }

  private async buildLocationTaskOptions(): Promise<Location.LocationTaskOptions> {
    const tier = await this.resolveLocationTier()
    const accuracy = this.getLocationAccuracy(tier ?? "")
    return {
      accuracy,
      pausesUpdatesAutomatically: false,
    }
  }

  // Location cache helpers
  private isGoodAccuracy(accuracy?: number | null): boolean {
    return typeof accuracy === "number" && accuracy > 0 && accuracy <= this.GOOD_ACCURACY_METERS
  }

  private isCacheFresh(): boolean {
    return this.lastGoodLocation !== null && Date.now() - this.lastGoodLocation.timestamp <= this.CACHE_TTL_MS
  }

  public getCachedLocation(): {latitude: number; longitude: number; accuracy?: number} | null {
    if (this.lastGoodLocation && this.isCacheFresh()) {
      const {latitude, longitude, accuracy} = this.lastGoodLocation
      return {latitude, longitude, accuracy}
    }
    return null
  }

  public updateLocationCacheIfGood(loc?: Location.LocationObject | null): void {
    if (!loc) return
    const acc = loc.coords.accuracy
    if (this.isGoodAccuracy(acc)) {
      this.lastGoodLocation = {
        latitude: loc.coords.latitude,
        longitude: loc.coords.longitude,
        accuracy: acc ?? undefined,
        timestamp: Date.now(),
      }
    }
  }

  // Prefer a fresh cached good fix over a newly delivered poor fix.
  // Fallback order: good new fix -> fresh cached good fix -> any new fix -> null
  public getBestLocationForSend(
    newLoc?: Location.LocationObject | null,
  ): {coords: {latitude: number; longitude: number; accuracy?: number}; fromCache: boolean} | null {
    if (newLoc && this.isGoodAccuracy(newLoc.coords.accuracy ?? undefined)) {
      return {
        coords: {
          latitude: newLoc.coords.latitude,
          longitude: newLoc.coords.longitude,
          accuracy: newLoc.coords.accuracy ?? undefined,
        },
        fromCache: false,
      }
    }

    const cached = this.getCachedLocation()
    if (cached) {
      return {coords: cached, fromCache: true}
    }

    if (newLoc) {
      // No fresh good cache and new fix is not "good", but still send something if available
      return {
        coords: {
          latitude: newLoc.coords.latitude,
          longitude: newLoc.coords.longitude,
          accuracy: newLoc.coords.accuracy ?? undefined,
        },
        fromCache: false,
      }
    }

    return null
  }

  private async applyLocationUpdatesMode(mode: string | null) {
    const normalized: "head_up" | "always_on" = mode === "always_on" ? "always_on" : "head_up"
    this.locationUpdatesMode = normalized
    const shouldWantUpdates = normalized === "always_on" || (normalized === "head_up" && this.isHeadUp)
    this.wantLocationUpdates = shouldWantUpdates

    if (shouldWantUpdates) {
      await this.startLocationUpdatesIfNeeded()
    } else {
      await this.stopLocationUpdatesIfNeeded()
    }
  }

  private async startLocationUpdatesIfNeeded() {
    if (!this.wantLocationUpdates) {
      return
    }
    if (this.locationUpdatesActive || this.locationUpdatesStarting) {
      return
    }

    this.locationUpdatesStarting = true
    try {
      const options = await this.buildLocationTaskOptions()
      if (!this.wantLocationUpdates) {
        return
      }

      await Location.startLocationUpdatesAsync(LOCATION_TASK_NAME, options)
      this.locationUpdatesActive = true
    } catch (error) {
      console.error("Mantle: Error starting location updates", error)
      this.locationUpdatesActive = false
    } finally {
      this.locationUpdatesStarting = false
    }
  }

  private async stopLocationUpdatesIfNeeded() {
    if (this.locationUpdatesStopping) {
      return
    }

    this.locationUpdatesStopping = true
    try {
      const hasStarted = await Location.hasStartedLocationUpdatesAsync(LOCATION_TASK_NAME)
      if (hasStarted) {
        await Location.stopLocationUpdatesAsync(LOCATION_TASK_NAME)
      }
      this.locationUpdatesActive = false
    } catch (error) {
      console.error("Mantle: Error stopping location updates", error)
    } finally {
      this.locationUpdatesStopping = false
      this.locationUpdatesStarting = false
    }
  }

  private async restartLocationUpdatesIfNeeded() {
    if (!this.wantLocationUpdates) {
      return
    }
    await this.stopLocationUpdatesIfNeeded()
    await this.startLocationUpdatesIfNeeded()
  }

  public async setLocationUpdatesMode(mode: string) {
    await this.applyLocationUpdatesMode(mode)
  }

  public getLocationAccuracy(accuracy: string) {
    switch (accuracy) {
      case "realtime":
        return Location.LocationAccuracy.BestForNavigation
      case "tenMeters":
        return Location.LocationAccuracy.High
      case "hundredMeters":
        return Location.LocationAccuracy.Balanced
      case "kilometer":
        return Location.LocationAccuracy.Low
      case "threeKilometers":
        return Location.LocationAccuracy.Lowest
      case "reduced":
        return Location.LocationAccuracy.Lowest
      default:
        // console.error("Mantle: unknown accuracy: " + accuracy)
        return Location.LocationAccuracy.Balanced
    }
  }

  public async setLocationTier(tier: string) {
    console.log("Mantle: setLocationTier()", tier)
    this.cachedLocationTier = tier
    if (this.wantLocationUpdates) {
      await this.restartLocationUpdatesIfNeeded()
    }
  }

  public async requestSingleLocation(accuracy: string, correlationId: string) {
    console.log("Mantle: requestSingleLocation()")
    try {
      // If we have a fresh good fix cached, use it immediately
      const cached = this.getCachedLocation()
      if (cached) {
        socketComms.sendLocationUpdate(cached.latitude, cached.longitude, cached.accuracy ?? undefined, correlationId)
        return
      }

      // Otherwise fetch a new fix, update cache if good, then choose best to send
      const location = await Location.getCurrentPositionAsync({accuracy: this.getLocationAccuracy(accuracy)})
      this.updateLocationCacheIfGood(location)
      const best = this.getBestLocationForSend(location)
      if (!best) return

      socketComms.sendLocationUpdate(
        best.coords.latitude,
        best.coords.longitude,
        best.coords.accuracy ?? undefined,
        correlationId,
      )
    } catch (error) {
      console.error("Mantle: Error requesting single location", error)
    }
  }

  public async handleHeadPosition(isUp: boolean) {
    this.isHeadUp = isUp
    if (this.locationUpdatesMode === "always_on") {
      this.wantLocationUpdates = true
      await this.startLocationUpdatesIfNeeded()
      return
    }

    this.wantLocationUpdates = isUp
    if (isUp) {
      await this.startLocationUpdatesIfNeeded()
    } else {
      await this.stopLocationUpdatesIfNeeded()
    }
  }

  public async handleLocalTranscription(data: any) {
    // TODO: performance!
    const offlineStt = await useSettingsStore.getState().loadSetting(SETTINGS_KEYS.offline_captions_app_running)
    if (offlineStt) {
      this.transcriptProcessor.changeLanguage(data.transcribeLanguage)
      const processedText = this.transcriptProcessor.processString(data.text, data.isFinal ?? false)

      // Scheduling timeout to clear text from wall. In case of online STT online dashboard manager will handle it.
      if (data.isFinal) {
        console.log("Mantle: isFinal, scheduling timeout to clear text from wall")
        if (this.clearTextTimeout) {
          console.log("Mantle: canceling pending timeout")
          clearTimeout(this.clearTextTimeout)
        }
        this.clearTextTimeout = setTimeout(() => {
          console.log("Mantle: clearing text from wall")
          socketComms.handle_display_event({
            type: "display_event",
            view: "main",
            layout: {
              layoutType: "text_wall",
              text: "",
            },
          })
        }, 10000) // 10 seconds
      }

      if (processedText) {
        socketComms.handle_display_event({
          type: "display_event",
          view: "main",
          layout: {
            layoutType: "text_wall",
            text: processedText,
          },
        })
      }

      return
    }

    if (socketComms.isWebSocketConnected()) {
      socketComms.sendLocalTranscription(data)
      return
    }
  }
}

const mantle = MantleManager.getInstance()
export default mantle
