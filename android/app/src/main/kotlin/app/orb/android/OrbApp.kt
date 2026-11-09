package app.orb.android

import android.app.Application

class OrbApp : Application() {
    override fun onCreate() {
        super.onCreate()
        OrbRepository.get(this).notifier = Notifier(this)
    }
}
