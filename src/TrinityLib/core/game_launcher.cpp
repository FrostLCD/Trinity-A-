#include "TrinityLib/core/game_launcher.hpp"
#include "TrinityLib/core/discord_manager.hpp"
#include "TrinityLib/core/version_config.hpp"
#include "TrinityLib/core/version_manager.hpp"
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QSettings>
#include <QStandardPaths>
#include <QFileDevice>
#include <iostream>

GameLauncher::GameLauncher(QObject *parent)
    : QObject(parent),
      m_isClosing(false) {

    m_process = new QProcess(this);
    m_killTimer = new QTimer(this);

    // Configurar el Terminator (Timer)
    m_killTimer->setSingleShot(true);
    m_killTimer->setInterval(3000); // 3 segundos de tolerancia
    connect(m_killTimer, &QTimer::timeout, this, &GameLauncher::forceKillGame);

    m_process->setProcessChannelMode(QProcess::MergedChannels);

    // Conectamos la lectura de logs
    connect(m_process, &QProcess::readyReadStandardOutput, this,
            &GameLauncher::onGameOutput);

    // Conectamos el fin del juego
    connect(m_process,
            QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
            [this](int code, QProcess::ExitStatus status) {
                // Si el juego termina bien, detenemos el timer de asesinato
                if (m_killTimer->isActive())
                    m_killTimer->stop();

                m_isClosing = false;

                DiscordManager::instance().updateActivityMain();
                emit gameFinished(code, status);
            });
}

GameLauncher::~GameLauncher() {
    if (m_process->state() == QProcess::Running) {
        m_process->kill(); // Destrucción total al cerrar el launcher
    }
}

void GameLauncher::onGameOutput() {
    // Read all the terminal logs
    QByteArray data = m_process->readAllStandardOutput();
    QString output = QString::fromLocal8Bit(data);

    emit gameOutput(output);

    std::cout << data.toStdString();

    // Messages logs of bedrock close
    if (!m_isClosing && (output.contains("Invoking stop activity callbacks") ||
                         output.contains("The graphics context was lost") ||
                         output.contains("Quit request received") ||
                         output.contains("Android window closed"))) {

        m_isClosing = true;
        DiscordManager::instance().updateActivityMain();

        m_process->terminate();
        m_killTimer->setInterval(2000);
        m_killTimer->start();
    }
}

void GameLauncher::forceKillGame() {
    if (m_process->state() != QProcess::NotRunning)
        m_process->kill(); // SIGKILL
}

bool GameLauncher::launchGame(const QString &versionName, QString &errorMsg) {
    if (m_process->state() != QProcess::NotRunning) {
        errorMsg = tr("The game is already running.");
        return false;
    }

    m_isClosing = false; // Resetear bandera

    VersionManager vm;
    QString dataDir = vm.getVersionPath(versionName);
    QString appDir = QCoreApplication::applicationDirPath();

    // Check if the version has /lib/x86 folder (32-bit version)
    QString libX86Path = dataDir + "/lib/x86";
    bool isX86Version = QFileInfo::exists(libX86Path);

    // Select the appropriate client based on architecture
    QString clientBaseName = isX86Version ? "mcpelauncher-client86" : "mcpelauncher-client";
    // Flatpak puts bundled helpers in /app/bin.  Keep the application-local
    // and PATH lookups for AppImage/native installs, but only accept an
    // executable file; passing a non-existent path to QProcess otherwise
    // produces the unhelpful "Could not start..." message.
    const QStringList candidates = {
        appDir + "/" + clientBaseName,
        QStringLiteral("/app/bin/") + clientBaseName,
        QStandardPaths::findExecutable(clientBaseName)
    };
    QString clientPath;
    for (const QString &candidate : candidates) {
        if (!candidate.isEmpty() && QFileInfo(candidate).isFile() &&
            QFileInfo(candidate).isExecutable()) {
            clientPath = QFileInfo(candidate).canonicalFilePath();
            break;
        }
    }

    if (clientPath.isEmpty()) {
        errorMsg = tr("%1 was not found or is not executable.\n"
                      "Checked: %2\n"
                      "Install the mcpelauncher runtime or rebuild the Flatpak.")
            .arg(clientBaseName, candidates.join(", "));
        emit gameOutput("[Trinity] " + errorMsg + "\n");
        return false;
    }

    VersionConfig config(versionName);
    QString extraEnvStr = config.getLaunchArgs();
    QStringList args;
    args << "-dg" << dataDir
         << "-dd" << VersionManager::getDataRoot();

    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    // The native client uses this to locate bridge assets and it is also
    // useful when launching from a desktop file where the host environment
    // does not contain mcpelauncher's data path.
    env.insert("MCPELAUNCHER_DATA_DIR", VersionManager::getDataRoot());
    if (VersionManager::isFlatpak()) {
        const QString bundledLibs = QStringLiteral("/app/lib");
        const QString oldLibraryPath = env.value("LD_LIBRARY_PATH");
        env.insert("LD_LIBRARY_PATH", oldLibraryPath.isEmpty()
            ? bundledLibs
            : bundledLibs + ":" + oldLibraryPath);
    }
    if (!extraEnvStr.isEmpty()) {
        // Parse KEY=VALUE entries separated by newlines and/or spaces.
        // Uses KEY= occurrences as delimiters so values that contain spaces
        // are handled correctly (e.g. "MY_PATH=/usr/local/my dir" stays intact).
        //
        // Examples that all work:
        //   "DRI_PRIME=1\nvblank_mode=0"          -> two variables (newline-separated)
        //   "DRI_PRIME=1 vblank_mode=0"            -> two variables (space-separated)
        //   "MY_PATH=/usr/local/mi carpeta"        -> one variable, value has a space
        //   "MY_PATH=/usr/local/mi carpeta LIBVA_DRIVER_NAME=radeonsi" -> two variables,
        //                                             first value has a space
        static const QRegularExpression keyRe(
            R"((?:^|(?<=\s))([A-Za-z_][A-Za-z0-9_]*)=)");

        QStringList lines = extraEnvStr.split('\n', Qt::SkipEmptyParts);
        for (const QString &line : lines) {
            QList<QRegularExpressionMatch> matches;
            auto it = keyRe.globalMatch(line);
            while (it.hasNext())
                matches.append(it.next());

            for (int i = 0; i < matches.size(); i++) {
                const QString &key = matches[i].captured(1);
                int valueStart     = matches[i].capturedEnd(0); // right after '='
                // Value extends until where the next key name starts,
                // or to the end of the line if this is the last variable.
                int valueEnd = (i + 1 < matches.size())
                               ? matches[i + 1].capturedStart(1) // start of next key name
                               : line.size();
                QString value = line.mid(valueStart, valueEnd - valueStart).trimmed();
                if (!key.isEmpty())
                    env.insert(key, value);
            }
        }
    }

    // Apply compatibility toggles configured in the Content Manager
    QSettings settings;
    if (settings.value("renderer/force_vibrants", false).toBool())
        env.insert("force_gl_renderer", "Adreno (TM) 740");
    if (settings.value("renderer/old_intel", false).toBool()) {
        env.insert("MESA_LOADER_DRIVER_OVERRIDE", "i965");
        env.insert("MESA_NO_ERROR", "1");
        // On Gen7 Intel the iris driver fails to render (black screen). The
        // classic i965 driver must be forced, and on a pure Wayland session
        // SDL also needs an explicit backend, otherwise EGL falls back to
        // llvmpipe. Only force it under Wayland so X11 sessions keep working.
        if (qgetenv("XDG_SESSION_TYPE") == "wayland")
            env.insert("SDL_VIDEODRIVER", "wayland");
    }
    if (settings.value("renderer/nvidia", false).toBool()) {
        env.insert("__NV_PRIME_RENDER_OFFLOAD", "1");
        env.insert("__VK_LAYER_NV_optimus", "NVIDIA_only");
        env.insert("__GLX_VENDOR_LIBRARY_NAME", "nvidia");
    }
    if (settings.value("renderer/zink", false).toBool()) {
        env.insert("MESA_LOADER_DRIVER_OVERRIDE", "zink");
        env.insert("GALLIUM_DRIVER", "zink");
        env.insert("__GLX_VENDOR_LIBRARY_NAME", "mesa");
    }
    if (settings.value("renderer/glvk_fps", false).toBool()) {
        env.insert("mesa_glthread", "true");
        env.insert("ANV_SPARSE", "1");
        env.insert("MESA_NO_ERROR", "1");
    }
    if (settings.value("renderer/black_screen", false).toBool()) {
        env.insert("MESA_GL_VERSION_OVERRIDE", "3.3");
        env.insert("MESA_GLES_VERSION_OVERRIDE", "3.1");
        env.insert("allow_glsl_extension_directive_mid_module", "true");
    }

    // Per-version GPU selection (manual: automatic / iGPU / dGPU)
    const QString gpuChoice =
        settings.value("gpu/choice/" + versionName, "auto").toString();
    if (gpuChoice == "igpu") {
        env.remove("__NV_PRIME_RENDER_OFFLOAD");
        env.remove("__VK_LAYER_NV_optimus");
        env.remove("__GLX_VENDOR_LIBRARY_NAME");
        env.insert("DRI_PRIME", "0");
    } else if (gpuChoice == "dgpu") {
        env.insert("DRI_PRIME", "1");
        env.insert("__NV_PRIME_RENDER_OFFLOAD", "1");
        env.insert("__VK_LAYER_NV_optimus", "NVIDIA_only");
        env.insert("__GLX_VENDOR_LIBRARY_NAME", "nvidia");
    }
    m_process->setProcessEnvironment(env);
    m_process->setWorkingDirectory(dataDir);

    QString displayServer =
        qgetenv("XDG_SESSION_TYPE") == "wayland" ? "Wayland" : "X11";
    QString state = "Ver: " + versionName + " (" + displayServer + ")";

    DiscordManager::instance().updateActivity(
        tr("Playing Minecraft Bedrock"), // Details
        state,                           // State
        "mc_icon",                       // Small Image
        "Linux",                         // Tooltip
        true                             // Timer: SÍ
    );

    m_process->setProgram(clientPath);
    m_process->setArguments(args);
    m_process->start();

    if (!m_process->waitForStarted(3000)) {
        errorMsg = tr("Could not start the game process.\n"
                      "Executable: %1\n"
                      "Reason: %2")
            .arg(clientPath, m_process->errorString());
        emit gameOutput("[Trinity] " + errorMsg + "\n");
        DiscordManager::instance().updateActivity(
            tr("Trinity A+ Menu"), tr("Waiting..."));
        return false;
    }

    return true;
}

// Implementaremos un método para forzar el cierre si es necesario
// (Opcional: puedes conectar la señal stateChanged para monitorear)
