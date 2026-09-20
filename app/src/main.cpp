#include "TrinityLib/ui/app_helpers.hpp"
#include "TrinityLib/ui/windows/launcher_window.hpp"
#include <QApplication>
#include <QFontDatabase>
#include <QDebug>
#include <QGraphicsOpacityEffect>
#include <QPropertyAnimation>
#include <QSplashScreen>
#include <QTimer>
#include <QPixmap>
#include <TrinityLib/core/discord_manager.hpp>

int main(int argc, char *argv[]) {
    QApplication app(argc, argv);

    // Load Roboto font (clean modern sans-serif)
    int fontId = QFontDatabase::addApplicationFont(":/fonts/Roboto.ttf");
    if (fontId != -1) {
        QStringList fontFamilies = QFontDatabase::applicationFontFamilies(fontId);
        if (!fontFamilies.isEmpty()) {
            app.setFont(QFont(fontFamilies.first(), 11));
        }
    }

    // Load Pixellari font for title (pixel-style font)
    int pixellariFontId = QFontDatabase::addApplicationFont(":/fonts/Pixellari.ttf");
    if (pixellariFontId != -1) {
        qDebug() << "[Font] Pixellari loaded successfully";
    }

    // Now more simpler!
    Trinity::UI::setupThemeAndLocale(app, "");

    DiscordManager::instance().init(1536805576200290314);
    DiscordManager::instance().updateActivityMain();

    QPixmap splashPixmap(":/branding/logo");
    QSplashScreen splash(splashPixmap.scaled(360, 360, Qt::KeepAspectRatio,
                                              Qt::SmoothTransformation),
                         Qt::WindowStaysOnTopHint);
    splash.setWindowFlag(Qt::FramelessWindowHint);
    splash.setStyleSheet("QSplashScreen { background: #10151f; }");
    auto *splashOpacity = new QGraphicsOpacityEffect(&splash);
    splash.setGraphicsEffect(splashOpacity);
    auto *splashFade = new QPropertyAnimation(splashOpacity, "opacity", &splash);
    splashFade->setDuration(700);
    splashFade->setStartValue(0.0);
    splashFade->setEndValue(1.0);
    splash.show();
    splashFade->start(QAbstractAnimation::DeleteWhenStopped);
    app.processEvents();

    LauncherWindow window;
    QTimer::singleShot(850, &splash, [&window, &splash]() {
        window.show();
        splash.finish(&window);
    });
    return app.exec();
}
