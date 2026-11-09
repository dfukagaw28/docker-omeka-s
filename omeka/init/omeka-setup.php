<?php
/**
 * Non-interactive setup for Omeka S.
 *
 * Usage: php omeka-setup.php <wait-db|install|migrate|modules>
 *
 *   wait-db  Wait until the database accepts connections.
 *   install  Install Omeka S (creates the first admin user) if not installed.
 *   migrate  Run pending core database migrations (after an Omeka upgrade).
 *   modules  Install/activate modules listed in modules.txt, and upgrade
 *            modules whose code is newer than the installed version.
 *            Failures are reported but do not stop the container.
 *
 * Settings are read from environment variables (see .env.sample).
 */

const OMEKA_DIR = '/var/www/html';
const MODULES_LIST = '/usr/local/share/omeka/modules.txt';

function env(string $name, ?string $default = null): ?string
{
    $value = getenv($name);
    return ($value === false || $value === '') ? $default : $value;
}

function out(string $message): void
{
    fwrite(STDOUT, "[omeka-setup] $message\n");
}

function fail(string $message): void
{
    fwrite(STDERR, "[omeka-setup] ERROR: $message\n");
    exit(1);
}

function bootstrap()
{
    require_once OMEKA_DIR . '/bootstrap.php';
    $application = Omeka\Mvc\Application::init(require OMEKA_DIR . '/application/config/application.config.php');
    return $application->getServiceManager();
}

/** Authenticate as the first global admin, as required by the module manager. */
function loginAsAdmin($services): void
{
    $em = $services->get('Omeka\EntityManager');
    $email = env('OMEKA_ADMIN_EMAIL');
    $user = $email ? $em->getRepository(Omeka\Entity\User::class)->findOneBy(['email' => $email]) : null;
    if (!$user) {
        $user = $em->getRepository(Omeka\Entity\User::class)->findOneBy(['role' => 'global_admin'], ['id' => 'ASC']);
    }
    if (!$user) {
        fail('No global admin user found.');
    }
    $services->get('Omeka\AuthenticationService')->getStorage()->write($user);
}

function waitDb(): void
{
    $dsn = sprintf('mysql:host=%s;port=%s;dbname=%s', env('DB_HOST', 'db'), env('DB_PORT', '3306'), env('DB_NAME', 'omeka'));
    $timeout = (int) env('OMEKA_DB_WAIT', '120');
    for ($i = 0; $i < $timeout; $i += 2) {
        try {
            new PDO($dsn, env('DB_USER', 'omeka'), env('DB_PASSWORD'));
            out('Database is ready.');
            return;
        } catch (PDOException $e) {
            if ($i === 0) {
                out('Waiting for the database...');
            }
            sleep(2);
        }
    }
    fail("Database not reachable after {$timeout}s: " . $e->getMessage());
}

function install(): void
{
    $services = bootstrap();
    if ($services->get('Omeka\Status')->isInstalled()) {
        out('Omeka S is already installed.');
        return;
    }

    $email = env('OMEKA_ADMIN_EMAIL');
    $password = env('OMEKA_ADMIN_PASSWORD');
    if (!$email || !$password) {
        fail('OMEKA_ADMIN_EMAIL and OMEKA_ADMIN_PASSWORD are required for the first installation.');
    }

    $installer = $services->get('Omeka\Installer');
    $installer->registerVars('Omeka\Installation\Task\CreateFirstUserTask', [
        'name' => env('OMEKA_ADMIN_NAME', 'Admin'),
        'email' => $email,
        'password-confirm' => ['password' => $password],
    ]);
    $installer->registerVars('Omeka\Installation\Task\AddDefaultSettingsTask', [
        'administrator_email' => $email,
        'installation_title' => env('OMEKA_TITLE', 'Omeka S'),
        'time_zone' => env('TZ', 'UTC'),
        'locale' => env('OMEKA_LOCALE', 'en_US'),
    ]);

    if (!$installer->install()) {
        fail("Installation failed:\n  " . implode("\n  ", array_map('strval', $installer->getErrors())));
    }
    out("Omeka S installed. Admin user: $email");
}

function migrate(): void
{
    $services = bootstrap();
    $status = $services->get('Omeka\Status');
    if (!$status->isInstalled()) {
        fail('Omeka S is not installed.');
    }
    if (!$status->needsMigration() && !$status->needsVersionUpdate()) {
        out(sprintf('Omeka S %s is up to date.', $status->getVersion()));
        return;
    }
    $services->get('Omeka\MigrationManager')->upgrade();
    $services->get('Omeka\Settings')->set('version', $status->getVersion());
    out(sprintf('Omeka S migrated to %s.', $status->getVersion()));
}

/** @return array<string, bool> module name => activate automatically */
function listedModules(): array
{
    $modules = [];
    foreach (file(MODULES_LIST, FILE_IGNORE_NEW_LINES) as $line) {
        $line = trim($line);
        if ($line === '' || $line[0] === '#') {
            continue;
        }
        $name = preg_split('/\s+/', $line)[0];
        $activate = $name[0] !== '!';
        $modules[ltrim($name, '!')] = $activate;
    }
    return $modules;
}

/**
 * Upgrade modules whose code is newer than the installed version, then install
 * (and thereby activate) listed modules that are not installed yet. A module
 * that was installed but later deactivated by an admin is left alone.
 *
 * Each module is handled in its own PHP process: modules are loaded once at
 * bootstrap, so a module that depends on another one (e.g. Log on Common)
 * can only be installed after a fresh bootstrap.
 */
function modules(): void
{
    $services = bootstrap();
    $manager = $services->get('Omeka\ModuleManager');

    $pending = [];
    foreach ($manager->getModulesByState($manager::STATE_NEEDS_UPGRADE) as $module) {
        $pending[] = ['upgrade-module', $module->getId()];
    }
    foreach (listedModules() as $id => $activate) {
        $module = $manager->getModule($id);
        if (!$module) {
            out("Module $id is listed but not present; skipped.");
        } elseif ($activate && $module->getState() === $manager::STATE_NOT_INSTALLED) {
            $pending[] = ['install-module', $id];
        }
    }

    $failed = 0;
    foreach ($pending as [$action, $id]) {
        passthru(escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg(__FILE__) . " $action " . escapeshellarg($id), $code);
        if ($code !== 0) {
            $failed++;
        }
    }
    if ($failed) {
        out("Warning: $failed module(s) could not be installed or upgraded; see the messages above.");
    }
}

function moduleAction(string $action, string $id): void
{
    $services = bootstrap();
    loginAsAdmin($services);
    $manager = $services->get('Omeka\ModuleManager');
    $module = $manager->getModule($id);
    if (!$module) {
        fail("Module $id not found.");
    }
    try {
        if ($action === 'install') {
            $manager->install($module);
            out("Installed module $id {$module->getIni('version')}.");
            applyModuleDefaults($services, $id);
        } else {
            $manager->upgrade($module);
            out("Upgraded module $id to {$module->getIni('version')}.");
        }
    } catch (Throwable $e) {
        fail("Could not $action module $id: " . $e->getMessage());
    }
}

/**
 * Settings applied once, right after a module is first installed (later
 * changes made in the admin UI are kept).
 */
function applyModuleDefaults($services, string $id): void
{
    $settings = $services->get('Omeka\Settings');
    switch ($id) {
        case 'IiifServer':
            // By default IiifServer adds image services (/iiif/2|3/<media>)
            // to manifests. Without an image server (ImageServer module) their
            // info.json is served but image requests fail (503), so viewers
            // show no image. Reference the image files instead; configure an
            // external image server (e.g. IIPImage) in the module config when
            // there is one. All of these are needed to drop the services from
            // both v2 and v3 manifests.
            $settings->set('iiifserver_media_api_default_version', '0');
            $settings->set('iiifserver_media_api_default_supported_version', ['service' => '0', 'level' => '0']);
            foreach (['1', '2', '3'] as $version) {
                $settings->set('iiifserver_media_api_supported_version_' . $version, '');
            }
            out('IiifServer: image server disabled (images are served as files).');
            break;
    }
}

$command = $argv[1] ?? '';
switch ($command) {
    case 'wait-db': waitDb(); break;
    case 'install': install(); break;
    case 'migrate': migrate(); break;
    case 'modules': modules(); break;
    case 'install-module': moduleAction('install', $argv[2] ?? ''); break;
    case 'upgrade-module': moduleAction('upgrade', $argv[2] ?? ''); break;
    default:
        fwrite(STDERR, "Usage: php omeka-setup.php <wait-db|install|migrate|modules>\n");
        exit(2);
}
