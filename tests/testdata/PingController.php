<?php
namespace App\Controller;

use Symfony\Component\HttpFoundation\Response;

final class PingController
{
    public function __invoke(): Response
    {
        return new Response('roadrunner-symfony-ok pid=' . getmypid());
    }
}
